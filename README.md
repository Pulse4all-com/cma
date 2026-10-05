# Contactcenter-Management-App (CMA)

The Contactcenter-Management-App (CMA) is a standalone application for managing a contact center that runs on a **CRM plus a telephony tool**. That setup is everywhere (HubSpot, Zoho, ActiveCampaign, … with Aircall, another softphone or the CRM's own calling), and none of those tools manage the people doing the work: who is clocked in, who covers which skill, who gets the next lead, how productive the team is. The CMA is that missing layer. Agents log in to start their day, managers plan and steer their team, and leads are routed to the right available agent within seconds.

Built first for Pulse4all AED subscriptions (HubSpot + Aircall), then copied to Pulse4all Invest, then offered to other companies. Agents and managers use it at **workspace.pulse4all.app**.

**Team:** Martin, Joshua, Finn
**Key stakeholders:** Arno (call center manager), Kira, Peter, Bas (dashboards and reporting), Yordi (compliance and data protection)

---

## Guiding principles

1. **Design for many, build for one.** Nothing Pulse4all-specific, HubSpot-specific or Aircall-specific is hardcoded. Markets, skills, channels, statuses, rules and thresholds are tenant configuration; the CRM and the telephony tool are adapters per tenant; system names appear only as data values. We build the Pulse4all version first and add a second adapter when there is a second customer, not before.
2. **Open.** The data layer is accessible to other applications through an API, so others can read from it, write to it and build on top of it.
3. **Right the first time.** Isolation per customer, multi-tenancy (data strictly separated per business line), roles and permissions, and a change history are part of the foundation from the first table, not added later.
4. **Step by step, straight to production.** Build one working piece in dev, verify it, promote it to production, then start the next piece in dev. Production runs from the first increment; we never build the whole platform first. Always take the clean choice over the quick shortcut.
5. **Use the right tool for each job.** Don't force one system to do everything.

---

## Why standalone and not inside the CRM

HubSpot stays our CRM and the source of truth for leads, deals, tickets and owners. The CMA is deliberately built **outside** HubSpot, on its own foundation. We looked at building it inside HubSpot and decided against it for these reasons:

1. **This is not CRM work.** A time clock that starts on login, work statuses, rosters with skill coverage, automatic logout on the scheduled end time, realtime messages to agents and gamification are workforce and call center functions. HubSpot is not designed for them. Building them inside HubSpot means forcing them into custom objects and workarounds that stay fragile and limited.
2. **Live, all-day use needs a fast database.** Every agent keeps the CMA open all day, and managers watch live views. Running that directly on HubSpot hits API rate limits and slows down. Postgres is built for many concurrent reads and writes and handles hundreds of thousands of rows without effort.
3. **We combine more than HubSpot.** Aircall calls and recordings, the shared Gmail mailbox and later Shopify, the customer portal and NetSuite all feed productivity and steering. A neutral data layer brings these together; HubSpot would only see its own part.
4. **We own the data and the logic.** Time registration affects pay and labour rules and needs a complete, reliable history under our control. Our own Postgres plus BigQuery gives us that, plus open APIs for other tools to build on.
5. **Reusable across business lines and companies.** Built once and configured per tenant, the same CMA runs for Subscriptions and for Invest, and for another company on another CRM, without rebuilding it in each setup.
6. **Cost and flexibility.** The HubSpot features needed to stretch this far (custom objects at scale, advanced developer features) sit in the most expensive tiers, and we would still be limited by what HubSpot allows. A custom build costs effort up front but removes that ceiling.

HubSpot remains fully part of the flow: leads are assigned to owners in HubSpot, agents do their customer work in HubSpot and Aircall, and a HubSpot app card can serve as a shortcut to the CMA. The same reasoning holds for Zoho, ActiveCampaign or any other CRM a customer runs.

---

## Customers, databases and tenants

Separation has two levels.

| Level | What it is | Separation | Example |
|---|---|---|---|
| Customer | one company (or group) that uses the CMA | its own database, logins, secrets and readers | Pulse4all |
| Tenant | one business line within a customer | `tenant_id` and row-level security inside the customer's database | Pulse4all Subscriptions, Pulse4all Invest |

- Pulse4all Subscriptions and Pulse4all Invest are two tenants in **one** database.
- Every new customer gets a **new** database. Nothing in one customer's database can see another customer, so analytics on a database may see all tenants of that customer by default.
- The same migrations run in every customer database. From the second customer on, a customer registry and a migration runner (control plane) are needed; until then it is one database and a checklist.
- Whether a customer gets its own Cloud SQL instance or project, or a separate database on a shared instance, is decided at the first external customer (see Open decisions). IAM database users and the superuser are instance-level, so instance or project per customer is the stronger boundary.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  CMA (agent, supervisor, manager, analytics views)         │
└───────────────┬───────────────────────────┬────────────────┘
                │                           │
                ▼                           ▼
┌───────────────────────────┐   ┌───────────────────────────┐
│  Postgres (Cloud SQL, EU) │   │  Realtime push service    │
│  one database per customer│   │  (push to agents, chat)   │
│  cma: operational tables  │   └───────────────────────────┘
│  cma_read: reporting views│   ┌───────────────────────────┐
└───────┬───────────┬───────┘   │  Scheduler / worker       │
        │           │           │  (lead expiry, auto-      │
        │           │           │   logout, period close)   │
        │           │           └───────────────────────────┘
        │           └──► cma_read ──► BigQuery (analytics)
        │                         └─► NocoDB (read-only)
        ▼
   Ingest API (Cloud Run): canonical entities in, actions out
        ▲
        │
   Adapters per tenant (Make scenarios today): CRM · telephony
        ▲
        │
┌──────────────────────────────────────────────────────────┐
│  SOURCES: CRM (HubSpot) · telephony (Aircall)            │
│  · Gmail (team@pulse4all.com)                            │
│  later: Shopify · customer portal · NetSuite             │
└──────────────────────────────────────────────────────────┘
```

**Layers**

- **Sources.** Per tenant a CRM and a telephony tool, plus whatever else feeds productivity. For Pulse4all: HubSpot (CRM, leads, deals, tickets, owners) and Aircall (calls, recordings, phone numbers) are the starting sources, the shared Gmail mailbox feeds support productivity, and Shopify, the customer portal and NetSuite come later.
- **Adapters and the canonical model.** Postgres stores canonical entities (lead, deal, call, ticket, owner, contact reference) with a fixed shape plus `source_system`, `source_id`, `synced_at` and the original payload in `raw`. An adapter maps one source system into that shape and executes the actions the CMA issues from its outbox (assign owner, update a status). Today the adapters are Make scenarios for HubSpot and Aircall; a second CRM is a second mapping, not a schema change. The ingest API contract is written against the canonical entities, never against a vendor payload.
- **Ingest API (Cloud Run).** The only write path from outside Google Cloud. Make, and later other tools, call it over HTTPS with a key per tenant; the key identifies the customer database and the tenant. It writes to Postgres through the Cloud SQL connector under its own service account. The database is never opened to external IP addresses. Decided 3 October 2026, over a direct Make connection, because Make's outbound IPs are shared with all Make customers in a zone.
- **Postgres on Google Cloud SQL (europe-west4).** The stable, fast foundation, one database per customer, in two schemas. `cma` holds the operational tables: tenants, people, roles, channels, and later rosters, statuses, time entries, skills, assignments, messages and synced CRM and call data, each with its change history. `cma_read` holds read-only reporting views and is the only thing readers ever see. Chosen over Airtable for volume (500k+ rows), stability and concurrent access from multiple points.
- **Readers.** BigQuery (analytics, federated connection in europe-west4 or the EU multi-region, one connection per customer database) and later NocoDB (read-only table browser) read `cma_read` through their own login users, never the base tables, so tables can change without breaking either and every exposed column is a deliberate choice.
- **Realtime push service.** A separate, specialised service for pushing messages to agents in the open CMA, later also chat. Postgres stays the record of every message; the service only delivers (see Messaging). Kept outside Cloud SQL on purpose; choice of service still open.
- **Scheduler / worker.** Time-based work: lead expiry after the accept window, automatic logout at the rostered end time, period closing, later reforecasts. Cloud Scheduler with a Cloud Run job, or pg_cron on Cloud SQL; choice open.
- **CMA.** The application agents and managers use all day, at workspace.pulse4all.app. It talks only to Postgres (and the push service), never directly to every source. It runs as a Cloud Run service in europe-west4 per project, with its own service account as `cma_app` member, connecting through the Cloud SQL Node.js connector with automatic IAM database authentication (no password anywhere). The screens reach Postgres in-process through the data layer; the same layer is exposed as a small JSON API under `/api/v1/me` (see API). Visitors reach it only through a global external Application Load Balancer with Identity-Aware Proxy (IAP) in front (see Web app and domain).

**Customer data.** The CMA does not display customer data; the agent works with customers in HubSpot and Aircall. Postgres does hold synced customer data, so it falls under the same GDPR care Pulse4all already applies to HubSpot and Aircall (EU hosting, access control, retention). Staff data (names, work emails, time and performance history, the audit log) is personal data too and gets a retention rule. Real staff data reaches prod with the first agent hours (Roadmap step 2), before any synced customer data; Yordi gets the heads-up on the new data store before that. Since 5 October 2026 prod holds the team's own working time (the first real workdays, through the screens); agents' hours follow only after the conditions in Roadmap step 2. The dev environment holds test data only; real data, staff or synced, lands only in prod. When another company's data lands in a CMA database, Pulse4all becomes a processor for that company, which needs a data processing agreement per customer (see Open decisions).

### Environments and infrastructure

Everything lives in the pulse4all.com Google Cloud organization, in the folder **Contactcenter-Management-App** (folder ID 641665155313; renamed from Callcenter-Management-App, decided 3 October and executed 4 October 2026; projects and the EU location policy unchanged). An organization policy on that folder only allows EU locations. Both projects are billed to the Pulse4all billing account, each with its own budget alert.

| Environment | Project | Role | Status |
|-------------|---------|------|--------|
| Dev | `p4a-cma-dev` | Sandbox for the next iteration; test data only | Live since 3 October 2026. Migration 0001, Pulse4all seed and dev test data verified 4 October 2026; migration 0002 (time model) with its dev fixture verified 5 October 2026; private `cma-web` on the database with mock identities and the API verifier (15 checks, provoked) since 5 October 2026 |
| Prod | `p4a-cma-prod` | Live; every verified increment; real data from the first agent hours (Roadmap step 2) onward | Live since 4 October 2026 with migration 0001 and the Pulse4all seed, verified the same day; migration 0002 verified 5 October 2026; on the database (`CMA_DATA_MODE=api`) since the evening of 5 October 2026, with Martin seeded as the first person |

**Dev database server `cma-dev-pg`:** PostgreSQL 18, Cloud SQL Enterprise edition, `db-g1-small` (shared core, no SLA, dev only), single zone in europe-west4. Daily backups at 01:00 UTC with point-in-time recovery, deletion protection, SSL required, IAM authentication on, maintenance week 1, Sunday 02:00 UTC. Database: `cma`. Budget alert €75 per month.

**Prod database server `cma-prod-pg`:** same edition, version, region and protection settings as dev, `db-g1-small` until real data lands (decision 4 October 2026), maintenance week 2 so dev receives updates a week earlier. The instance enforces a password policy for built-in logins (upper and lower case, digit and symbol). Dedicated-core machine with high availability comes before the first real agent hours (Roadmap step 2). Database: `cma`. Budget alert €150 per month.

**Web app and domain (prod), live since 4 October 2026:** Cloud Run service `cma-web` in europe-west4 with its own service account `cma-web@p4a-cma-prod.iam.gserviceaccount.com`, ingress limited to internal and Cloud Load Balancing, so the `run.app` address refuses everyone. In front of it a global external Application Load Balancer (`cma-web-backend`, `cma-web-urlmap`, `cma-web-proxy`, forwarding rule `cma-web-https`, HTTPS only on port 443) on the reserved address `cma-web-ip` (34.54.22.146), with a Google-managed certificate `cma-web-cert` for workspace.pulse4all.app. IAP on the backend admits only `cma@pulse4all.com` during the build; verified both ways on 4 October 2026 (a pulse4all.com account outside the group is refused). DNS for pulse4all.app is at IONOS: one A record `workspace` → 34.54.22.146; the other records (mail, root domain) are untouched. Cost about €18 per month for the forwarding rule; IAP has no charge. Chosen over Cloud Run domain mapping, which Google marks as preview and not recommended for production.

Since 5 October 2026 `cma-web` runs the CMA's own web application (image `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:<short sha>`) instead of Google's placeholder: My day, My hours, No access yet and Log out, with real IAP token verification. Since the evening of 5 October it runs on the database: `CMA_AUTH_MODE=iap`, `CMA_DATA_MODE=api`, `IAP_AUDIENCE=/projects/467777891162/global/backendServices/4482730491680652158`, `CMA_DB_INSTANCE=p4a-cma-prod:europe-west4:cma-prod-pg`, `CMA_DB_USER=cma-web@p4a-cma-prod.iam` (an IAM database user, member of `cma_app` with inheritance and without `SET ROLE`), `CMA_DB_NAME=cma`, `CMA_DB_POOL_MAX=5`, at most 4 instances (4 × 5 connections against the instance's 50). Both mode variables fail closed (unset means iap and api). These values are set by the build, not on the service (see Build and deploy). The page shows the deployed short SHA bottom left. Still to do before agents use it: `min-instances=1` against cold starts.

**Web app in dev, since 5 October 2026:** a private Cloud Run service `cma-web` in `p4a-cma-dev` (no unauthenticated access, so the `run.app` address answers 403), service account `cma-web@p4a-cma-dev.iam.gserviceaccount.com` with Cloud SQL Client and Cloud SQL Instance User, IAM database user `cma-web@p4a-cma-dev.iam` as `cma_app` member, `CMA_AUTH_MODE=mock`, `CMA_DATA_MODE=api`, at most 2 instances. It runs the image Cloud Build made for prod, by tag (build once, deploy many): dev's Cloud Run service agent has Artifact Registry reader on the `cma` repository in `p4a-cma-prod`, nothing else. A new image goes to dev with `gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=…/web:<short sha>`, which keeps the environment variables. Opened with `gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080`; the mock subject is chosen per request (see Authentication).

**Code:** private GitHub repository `Pulse4all-com/cma` (organisation owned by Pulse4all; Martin's account is Pulse4all-DEV) with `README.md`, `db/` (the migration, seed, fixture and verify scripts, `00` to `09`, in the repository since 5 October 2026), `web/` (the application), `cloudbuild.yaml` and `records/` (verify output per migration and environment, for example `records/0002-dev-2026-10-05`; the web app's own screenshots live under `records/web-<env>-<date>`). `web/` is Next.js 16 (App Router, Turbopack, TypeScript strict), Tailwind v4 with the Pulse4all tokens in `src/app/globals.css`, Montserrat shipped with the app; screens import data only through `src/lib/data` and identity only through `src/lib/auth/identity`, both with a mock implementation chosen by environment, so the API replaces the mocks without touching a component. All copy is in `src/lib/copy.ts` (English and Dutch). The Postgres side lives in `src/lib/db/client.ts` (connector, pool, transaction-local tenant context, SQLSTATE translation), `src/lib/data/postgres.ts` (the `CmaData` implementation) and `src/lib/api/respond.ts` with `src/app/api/v1/me/**` (the JSON API). Verifiers in `web/verify/` (copy, theme, layout, IAP token, API), each with a `--provoke` mode that must fail; the API verifier runs against dev through the proxy and needs the dev fixture `db/08_fixture_api_verify_dev.sql`. `db/09_seed_people_prod.sql` adds people with a Google login per tenant; it holds placeholders, never real Google ids.

**Working on the code:** from a clone in Cloud Shell (`~/cma`, logged in to GitHub with `gh` as Pulse4all-DEV, Node 22 through `nvm` to match the Docker image). Every change goes on a branch, passes `npm run build` with the repository's own TypeScript settings and its verifiers in Cloud Shell, then a pull request (`gh pr create`) and a squash merge. The real build runs before anything reaches `main`, which deploys to prod.

**Build and deploy:** Cloud Build in europe-west4, not GitHub Actions, so a later move to another Git host only changes the source setting. GitHub connection `cma-github` (Cloud Build repositories 2nd gen, authorised with the Pulse4all-DEV account, app installed on the Pulse4all-com organisation for `cma` only). Trigger `cma-web-main` runs `cloudbuild.yaml` on every push to `main` that touches `web/**` or `cloudbuild.yaml`: Docker build with the short SHA as version, push to Artifact Registry repository `cma` (europe-west4), `gcloud run deploy cma-web`. The build runs as service account `cma-build@p4a-cma-prod.iam.gserviceaccount.com` (Artifact Registry writer, Cloud Run admin, log writer, may act as `cma-web`), not the default Cloud Build account. Manual builds use `gcloud builds submit` with staging bucket `gs://p4a-cma-prod-build-src` (europe-west4; the default staging bucket is in the US and the EU-only folder policy refuses it). A build takes about two minutes on `E2_HIGHCPU_8`.

The deploy sets all of the service's environment variables at once (`--set-env-vars`), so `cloudbuild.yaml` and the trigger's substitutions are the one place `cma-web` is configured; a variable changed on the service by hand disappears at the next build. Substitutions: `_AUTH_MODE`, `_DATA_MODE`, `_IAP_AUDIENCE`, `_DB_INSTANCE`, `_DB_USER`, `_DB_NAME` (default `cma`), `_DB_POOL_MAX` (default 5), `_MAX_INSTANCES` (default 4); the file defaults to mock data. A first step, `check-config`, stops the build before anything is built or deployed when `_DATA_MODE=api` lacks `_DB_INSTANCE` or `_DB_USER`. The trigger is a 2nd-gen repository trigger: `gcloud builds triggers update github` refuses its substitutions (`INVALID_ARGUMENT`), so they are changed with `gcloud beta builds triggers export` → edit → `gcloud beta builds triggers import`, then `gcloud builds triggers run cma-web-main --branch=main`. Build status from the command line needs `--region=europe-west4`.

### Release flow: sandbox to production in small steps

- Dev is the sandbox, prod is live. Every increment that works and is verified in dev is promoted to prod; dev then moves on to the next iteration. Production exists from the first increment (migration 0001). We do not build the whole platform first and launch at the end.
- An increment ships with its migration, its verify script and a short release note. Promotion to prod: confirm point-in-time recovery is on (or take an on-demand backup), run the migration as `cma_owner` under a personal login, run the verify script, keep its output, then release the matching application or sync change.
- The verify output (screenshots or exported results) is kept per environment and date, for example `records/0001-dev-2026-10-04` and `records/0001-prod-2026-10-04`, next to the scripts in the repository.
- Migrations are forward-only and rerunnable. A mistake is fixed with a new migration, never by editing one that has shipped. From the second customer on, the same migration runs in every customer database.
- Prod holds real data from the first agent hours onward, dev never. Test data for a new feature lives in dev; a feature is only done when it is verified in prod.

### Data model: foundation (migration 0001)

Designed 3 October 2026 as the second half of Roadmap step 1; run and verified in dev and prod on 4 October 2026. Five scripts, run in Cloud SQL Studio for now, all safe to rerun:

| Script | Run as | Runs in | Does |
|---|---|---|---|
| `00_roles.sql` | `postgres`, once per database server | dev, prod | creates the database roles and the `bq_reader` login, grants them to the team logins; the only script that needs `postgres` |
| `01_foundation.sql` | your own IAM login | every database, unchanged | migration 0001: schemas, helpers, first tables, tenant separation, audit log, reporting views, permission catalog. Universal: no customer, tenant or vendor specifics |
| `02_seed_pulse4all.sql` | your own IAM login | dev and prod | customer configuration: the two tenants, their organisations and channels |
| `03_seed_dev_test_data.sql` | your own IAM login | dev only | fictional users, roles and CRM user ids (written for the V1 login screen, which is not built; replaced by Google account ids in the next dev seed) |
| `04_verify.sql` | your own IAM login | dev and prod | proves ownership, separation, fail-closed behaviour and the audit trail; block A is universal, B to H use the seeds |
| `05_time_model.sql` | your own IAM login | every database, unchanged | migration 0002: the time model, see the next section |
| `06_seed_dev_time_model.sql` | your own IAM login | dev only | mock login ids for the test users, a personal time zone, a short time history written through the write functions |
| `07_verify_time_model.sql` | your own IAM login | dev and prod | blocks A to K; A, B, C, D, F, G, I, J are universal (they create throwaway users inside a rolled-back transaction), E, H, K use the dev fixture |

Every script except `00_roles.sql` starts with a guard that refuses to run as `postgres` (override for a declared emergency: `set cma.emergency = 'on'`), followed by `set role cma_owner`. Another customer gets its own seed file; the migration stays untouched. On a fresh database the order is migrations first (`01`, `05`, …), then the customer seed (`02`), then dev seeds; on an existing database a seed that touches a new column is rerun after the migration that adds it (`02` is guarded for this).

**Tenant = business line.** A tenant is one isolated environment with its own people, configuration and data, inside a customer's database. Pulse4all Subscriptions and Pulse4all Invest are the two tenants; every tenant-scoped table carries `tenant_id`. `cma.create_tenant(slug, name, timezone)` creates a tenant with the default role ladder.

**Tables**

| Table | Scope | Holds |
|---|---|---|
| `tenant` | global | one row per business line: slug, name, time zone, status |
| `permission` | global | what the application code can check (`roster.manage`, `leads.accept`, …); changed only by migrations |
| `schema_migration` | global | which migration scripts have run |
| `organisation` | tenant | employers of the people in a tenant: the company itself and partners such as the call center |
| `channel` | tenant | customer contact channels with an `is_synchronous` flag; phone and email today, sms, whatsapp, chat and more as rows later. Skills, routing rules, SLAs and metrics reference a channel, nothing assumes phone |
| `app_user` | tenant | people who use the CMA, any employer, any email domain; one row per person per tenant, never hard-deleted |
| `app_user_external_id` | tenant | the same person in other systems, keyed by system; for Pulse4all `google` (login), `hubspot_owner` (lead assignment), `aircall_user` (call matching). Another customer uses its own system keys |
| `app_role`, `role_permission` | tenant | the role ladder per tenant (agent, supervisor, manager, analytics), seeded identically for every tenant and adjustable per tenant |
| `user_role` | tenant | role grants, optionally scoped to a team or market; the same role can be granted per scope |
| `audit_log` | tenant | every insert, update and delete on every tenant-scoped table, with before and after image, timestamp and actor; insert-only |

**Tenant separation**

- Hard separation between customers is the database boundary (see Customers, databases and tenants). Everything below separates business lines within one customer.
- Row-level security on every tenant-scoped table. The application sets its context once per transaction with `set_config(..., true)`: `app.tenant_id`, `app.user_id` (the acting CMA user) and optionally `app.actor_label` (the acting process, for example `ingest-api:hubspot`). No tenant set means nothing is visible and every write is rejected.
- Composite foreign keys on `(tenant_id, id)`, so a role, team or employer from one tenant can never be attached to a row of another.
- `cma.setup_tenant_table(table)` applies RLS, grants and the audit trigger. One line per new table in every migration.
- This protects against a forgotten `WHERE`, not against a hostile application: the app is trusted for the tenant it authenticated.

**Database roles and logins**

| Role | Kind | Rights | Members |
|---|---|---|---|
| `cma_owner` | group | owns `cma` and `cma_read` and everything in them; used via `SET ROLE` for migrations and base-table fixes | Martin, Joshua, Finn (SET ROLE only); `postgres` for emergencies |
| `cma_app` | group | read and write on `cma` within the current tenant; insert-only on `audit_log` | ingest API service account (`cma-ingest@<project>.iam`); later the CMA backend |
| `cma_readonly` | group | SELECT on the `cma_read` views only, no rights on `cma`; sees all tenants of the customer unless the login user carries an `app.tenant_id` setting | `bq_reader`, later NocoDB readers; the team's own logins by default |
| `bq_reader` | login | BigQuery federated connection; the one password login, password in Secret Manager (`cma-<env>-bq-reader-password`), set via `gcloud sql users set-password` at Sync | |

Team members default to the reader view (the same surface BigQuery and NocoDB get), switch to `cma_owner` for migrations and to `cma_app` to test exactly what the application can see. Martin and Joshua hold ADMIN on the three roles, so Finn and service accounts are granted without using `postgres`. Each customer database has its own logins and secrets.

**Conventions for every migration**

- System names (hubspot, aircall, zoho, activecampaign, …) appear only as data values, never in table, column, function or role names
- Every migration starts with the personal-login guard and `set role cma_owner`, is rerunnable, and ships with its verify script, because it runs in dev, then in prod, later in every customer database
- Every script runs under a personal IAM login; `postgres` only for a declared emergency, so audit rows always name a person
- `timestamptz` everywhere; the business day is derived from the configured time zone (tenant now, site or market later)
- Facts such as time entries, lead assignments and notifications are append-only, with `occurred_at` (when it happened) and `recorded_at` (when we wrote it); a correction is a new row with reason and approver, and closed periods are locked
- Facts that affect pay, billing or reporting over time (employment, team membership, skills, rates, targets) carry `valid_from` and `valid_to` and are never overwritten
- Configurable catalogs carry semantic flags (paid, billable, productive, synchronous), never names only, so billing, adherence and SLAs never depend on a string match
- Synced data carries `source_system`, `source_id`, `synced_at` and the original payload in `raw`; ingest is idempotent on system and id
- Every table that reporting needs gets its `cma_read` view in the same migration, with its columns listed explicitly
- `uuidv7()` primary keys; status columns instead of hard deletes

**Access rules**

- No authorized networks. Nothing connects directly; access only goes through the Cloud SQL Auth Proxy, Cloud SQL connectors or Cloud SQL Studio, with a Google login.
- Make and other external tools never connect directly; they go through the ingest API.
- Everyone works under a personal IAM database login. Access is granted through the Google group `cma@pulse4all.com` (Cloud SQL Client, Instance User, Viewer on both projects) plus membership of the database roles above.
- Readers (BigQuery, NocoDB, analytics) never see base tables, only `cma_read`. Each connection gets its own login user; a reader is limited to one tenant by giving its login an `app.tenant_id` setting. Hard separation for dashboards within a customer lives in BigQuery (authorized views or row access policies per dataset).
- `bq_reader` is the only password login, because BigQuery federated connections authenticate with username and password, not IAM. Its password lives only in Secret Manager.
- The built-in `postgres` user is for setup and emergencies only. Its password lives only in Secret Manager (`cma-dev-postgres-password`, `cma-prod-postgres-password`), never in chat, email or screenshots. Generate passwords in Cloud Shell and set them with `gcloud`; the prod instance requires upper and lower case, a digit and a symbol, dev does not.
- The web app is reachable only through the load balancer and IAP; the Cloud Run address refuses direct traffic. Team access during the build through `cma@pulse4all.com`, agents through their pulse4all.com account plus an active `app_user` row
- A budget alert per project emails the billing admins (dev: €75 per month, prod: €150 per month).

### Data model: time model (migration 0002)

Designed and run on 5 October 2026 as the first half of Roadmap step 2; verified in dev (blocks A to K) and prod (A, B, C, D, F, G, I, J) the same day, records in `records/0002-dev-2026-10-05` and `records/0002-prod-2026-10-05`. Universal, no customer specifics; tested locally on PostgreSQL 16 before Cloud SQL.

**Tables**

| Table | Scope | Holds |
|---|---|---|
| `work_status` | tenant | the configurable status list (available, training, meeting, break, lunch by default), each with semantic flags `is_working` (the clock runs), `is_productive`, `is_paid`, `is_billable`, one `is_default` per tenant. Seeded for every tenant by `cma.seed_default_work_statuses()`, which `create_tenant` now calls; adjustable per tenant |
| `workday` | tenant | one row per user per business day in the user's zone, with the zone snapshotted at open. A header: `status`, `started_at` and `ended_at` are derived from the events by `cma.refresh_workday()`, never set by hand |
| `time_event` | tenant | the facts: `start`, `status`, `end`, append-only, with `occurred_at` and `recorded_at`. `source` is `user`, `system` (scheduler) or `correction`. A correction is a new row with `reason` and `approved_by`; it adds a missing event, replaces one (`supersedes_event_id`) or cancels one (kind `void`). One correction per event; a later correction supersedes the earlier correction |

Time zones: `app_user.timezone`, then `organisation.timezone`, then `tenant.timezone` (`cma.user_timezone()`); all three validated against the IANA names Postgres knows. Newco is `Europe/Madrid` in the Pulse4all seed.

**The write path.** The application never inserts into these tables. It calls `cma.open_workday()`, `cma.set_status()`, `cma.end_workday()` and `cma.correct_time_event()` as `cma_app` with `app.tenant_id` and `app.user_id` set; the same functions serve the scheduler (source `system`, `app.actor_label` set, no user) and any later tool. Rules enforced there: a user opens and ends only their own day; today's day is returned if it exists, open or ended (an ended day stays ended); a correction needs a reason, an approver, and `workday.team` for both the acting user and the approver; the resulting day must have exactly one start, at most one end and nothing after the end. Errors carry stable SQLSTATEs `CMA01` (no acting user) to `CMA05` (tenant configuration missing) so the API maps codes, not text. `cma_app` has no `update` or `delete` on `time_event` and no `delete` on `workday` and `work_status`.

**Views.** Each computation exists once as an unfiltered core view owned by `cma_owner` and granted to nobody (`time_event_effective_all`, `time_interval_all`, `workday_summary_all`), with two faces: `cma.<name>` for the application, filtered on the current tenant and empty when none is set, and `cma_read.<name>` for readers, filtered with `reader_sees()`. `workday_summary` gives working, productive, paid and billable seconds per day plus `is_capped`, `needs_correction` and `has_correction`. An open day that was never ended keeps running until the end of its business day, is capped there and flagged; a manager closes it through a correction, later the scheduler does. Reporting views added: `work_status`, `workday`, `time_event` (including superseded rows and corrections), `time_interval`, `workday_summary`; `organisation` and `app_user` gained `timezone`.

**Identity helpers.** `cma.find_tenants_for_identity(system, external_id)`, the one `SECURITY DEFINER` function, returns tenant ids only and is what the login calls before a tenant is known; `cma.user_permissions()` and `cma.has_permission()` resolve the role ladder for the API (scopes are ignored until teams and markets exist).

---

### API: the web app's data layer (since 5 October 2026)

The web app reads and writes Postgres **in-process**: screens and route handlers call `data()` from `src/lib/data`, which returns the Postgres implementation when `CMA_DATA_MODE=api` and the in-memory mock otherwise. There is no HTTP hop between the screens and the database. The ingest API for Make (Roadmap step 3) is a separate Cloud Run service with its own service account and per-tenant keys; it can lift `src/lib/db/client.ts`.

**Rules in every call.** One transaction per call with `app.tenant_id`, `app.user_id` and `app.actor_label` set by `set_config(…, true)`, so a pooled connection can never carry one request's tenant into the next. Own data only through the database: every read filters on `cma.current_user_id()`, the transaction's acting user, never on an id passed in. The database clock decides: `open_workday()` and `end_workday()` are called without a time. Today is the business date in the user's zone, computed in SQL. Minutes on screen are working seconds rounded down per day (which hours the agent sees stays open, see Open decisions). Errors keep their SQLSTATE; SQL text never reaches a screen.

**Login (`findPrincipal`).** `cma.find_tenants_for_identity(provider, subject)` without a tenant; exactly one tenant continues, none or several (no tenant picker yet) is "no access yet". Inside that tenant the `app_user` row, its employer, its zone (`cma.user_timezone`) and its role; a user without a role is "no access yet". With several roles the earliest grant is shown, without ranking role names. A database that cannot be reached is an error, never "no access".

**JSON API**, versioned, behind the same gate and identity as the screens, no tenant or user parameter anywhere, `cache-control: no-store`:

| Route | Does | Data |
|---|---|---|
| `GET /api/v1/me` | who the caller is: name, tenant, employer, role, zone | `findPrincipal` |
| `GET /api/v1/me/day?date=YYYY-MM-DD` | the caller's workday, default today in their zone; reading never clocks in | `getWorkday` |
| `POST /api/v1/me/day/end` | ends the caller's day today, same path as the button; an ended day is returned unchanged | `endWorkday` |
| `GET /api/v1/me/hours?from=&to=` | the caller's hours per day, at most 92 days per request | `getHours` |

Status codes: 401 no identity, 403 no access, `CMA01` 403, `CMA02` 404, `CMA03` 409, `CMA04` and invalid input 400, `CMA05` 500, database unreachable 503. The POST requires the header `x-cma-request: 1` and refuses a cross-site `Sec-Fetch-Site`, so another website cannot end someone's day through their IAP session; `/logout/end` keeps its same-origin check.

**Verification.** `web/verify/api.mjs` runs 15 checks against dev with the dev fixture: identity in two tenants and unknown identity refused, tenant from the identity only, two users with two days, hours show the caller's own day, a `userId` parameter cannot redirect hours, the corrected forgotten clock-out leaves no past day open or capped, the end's request header and cross-site guard, end ends the own day, login after end does not reopen, a second end and a log out change nothing, the other user's day untouched, the 92-day bound. All pass; with `--provoke` all 15 fail. Records in `records/api-dev-2026-10-05`.

---

## Source of truth

Every data type has exactly one system that owns it. Postgres mirrors and combines; it does not overrule the owner. The owners below are Pulse4all's; another customer fills in its own systems, the rule stays the same.

| Data | Owner (source of truth) |
|------|-------------------------|
| Lead and deal status, owner assignment | CRM (HubSpot) |
| Call attempts, call outcomes, recordings | Telephony (Aircall) |
| Support tickets | CRM (HubSpot) |
| Customer contact details (name, address) | To decide: Shopify or customer portal |
| Invoices, payment status, billing address | NetSuite |
| Orders (id, time, email, new or renewal) | Shopify, synced into HubSpot |
| Complaints, vulnerability, SLAs | CRM (HubSpot ticket category, contact field) |
| Call transcripts, sentiment, playbook results | Telephony AI (Aircall AI) |
| Reviews | To decide: review platform |
| Agents, roles, skills, rosters, statuses, time entries, quality scorecards, messages, change history | CMA (Postgres) |

---

## Users and roles

| Role | Example | Sees and does |
|------|---------|---------------|
| Agent | Call center agents (mostly in Barcelona) | Own day: clock, status, roster, workload, scores, incoming leads, messages |
| Supervisor | Team lead | Their own group of agents, live status and performance |
| Call center manager | Arno | Full operational environment: rosters, skill coverage, live team view, productivity, messaging, configuration |
| Analytics | Kira, Peter, Bas | Dashboards, KPIs and reporting. Kira (Head of Call Center) also uses live and quality monitoring, see KPIs section |

Roles and permissions are tenant-aware: every business line gets the same ladder with its own people. Roles are rows per tenant, seeded from one default ladder and adjustable; the permissions they bundle come from a catalog defined by the application code. A grant can be scoped (a supervisor for one team, a manager for one market). Users are not only the customer's own employees: each user belongs to an organisation (the company itself, the call center partner, …), so hours and results can be reported per employer. The same person in two business lines is two users.

---

## Features

### 1. Workday and time tracking
- Logging in starts the agent's workday and the time clock.
- Agents switch status during the day: available, break, lunch, training (configurable list, each status flagged as productive, paid, billable). Non-working statuses stop the clock.
- If an agent forgets to log out, the system closes the day at the scheduled end time from the roster.
- Full history of every clock-in, clock-out and status change, append-only; corrections are new rows with reason and approver. Time data is the heart of the system and must be reliable.
- The CMA stays open all day (second screen) and lands on a page with the agent's workload, daily reporting and light dashboarding.

### 2. Rostering (manager)
- Arno publishes rosters per market.
- Roster shows **skill coverage** per market per day: for example France on Tuesday, is sales covered, courtesy calls, outstanding payments, exchanges?
- One agent can hold many skills. An omniskilled agent covers multiple slots alone.
- Coverage shows not only *covered* but *how deeply covered*, so single-person dependencies are visible.

### 3. Skills
- Each agent has skills along three dimensions: **language** (French, German, ...), **work type** (sales, support, courtesy calls, outstanding payments, exchanges, ...) and **channel** (phone, email, later sms, whatsapp, chat, ...). All lists are configurable per tenant.
- Skills drive both rostering coverage and lead assignment.

### 4. Speed to lead
1. A lead comes in.
2. The system finds agents who are **available** and have the **matching skills**.
3. The lead or deal is assigned to that agent as owner in the CRM, through the tenant's CRM adapter (HubSpot for Pulse4all).
4. The agent gets an immediate push message in the CMA.
5. The agent **must click to accept** the lead.
6. If not accepted within **5 minutes** (configurable per tenant), the lead moves to the next available agent.

Every step is logged as an append-only event with timestamps: offered, delivered to the agent's screen, seen, accepted or declined, expired, reassigned. Speed-to-lead reporting and the accept rule both run on this log.

### 5. Productivity and steering (manager)
- Calls per agent per hour.
- Conversion: deals closed won / closed lost.
- Support: tickets closed, mail handled from the shared mailbox.
- At a glance: which agents outperform and which underperform, with sales and support work shown side by side so support-heavy agents are not misjudged.

### 6. Gamification (agent)
- Daily goals, scores, streaks and comparison with yesterday or colleagues, built from the same metrics the manager uses.
- Metrics must reward the right behaviour (not just volume, not just easy conversions).

### 7. Messaging
- Managers and supervisors push messages directly to agents in the open CMA; later 1:1 and team chat, announcements that must be acknowledged, and an assist request from agent to supervisor.
- Every message is a row in Postgres with one delivery row per recipient (`delivered_at`, `read_at`, `acknowledged_at`). Group targets (team, market, all) are resolved into delivery rows at send time, so history stays exact when teams change.
- Pushing goes through an outbox: the application writes the message and the outbox row in one transaction, a relay forwards to the realtime service, acknowledgements flow back. Nothing is lost if the push service hiccups.
- Messages carry references (CRM id, case status, link), never customer data. Delivery respects quiet hours and working time; Spain has a statutory right to disconnect.
- Later channels for reaching users (email, mobile push) are extra delivery rows behind the same message.

---

## Target scope beyond V1

The CMA covers everything needed to manage the contact center besides the calling itself, the customer channels and the CRM. V1 builds the first slices (Roadmap steps 2 and 5 to 7); the foundation is designed so the rest can be added without reworking what exists.

| Module | Covers | Main users |
|---|---|---|
| Organisation | tenant settings, markets, office hours and holidays per market, sites and time zones, teams and hierarchy, employers, activity codes, skill and channel lists, roles, integrations and adapters (CRM, telephony), API keys, audit, retention | manager, admin |
| People and staffing | identity, employment history (employer, contract type, hours, start and end), skills with proficiency and validity, availability and preferences, onboarding and offboarding | manager, HR at the partner |
| Time and attendance | clock, statuses, breaks, adherence (planned vs actual), corrections with approval, timesheet approval and locked periods, leave and balances, overtime and rest rules | agent, supervisor, manager |
| Rostering | shift templates, roster versions and publication, coverage requirements per market, work type and channel per interval, swaps and requests, forecasting from historical volume, intraday reforecast | manager, supervisor, agent |
| Routing | assignment rules per tenant, market and channel, queues, accept and expiry events, fallback and escalation, full trail | system, agent, manager |
| Performance and quality | metric catalog with definitions, targets per role, team and period, scorecards as versioned forms, calibration, disputes, coaching and action plans, gamification | supervisor, manager, analytics, agent |
| Communication | push, broadcasts, must-acknowledge announcements, chat, assist requests, preferences and quiet hours, mobile push | everyone |
| Billing and cost | rates per employer, role and work type with validity, billable and paid flags, approved hours per period, outcome counts, exports; invoicing itself stays in NetSuite | manager, finance |
| Reporting | live views and wallboards, agent dashboards, weekly and trend reports, as-of reporting (who was in which team, on which contract, on a given date) | all roles |
| Compliance | staff data under GDPR, retention per data type, employee monitoring rules in NL and Spain, right to disconnect, who-saw-what for sensitive alerts | Yordi, manager |
| Platform | customer registry, database provisioning, migration runner across customer databases, adapter catalog, onboarding checklist per customer; needed from the second customer on | CMA team |

---

## KPIs and steering for the Head of Call Center

This section is Pulse4all's configuration of the metric catalog: deal stages, closed-lost reasons, markets and UK rules are tenant settings, not product rules. Another customer defines its own.

Kira steers the call center on six outcomes: **conversion (speed to lead), indirect sales, reviews as high as possible, churn as low as possible, and complaints and vulnerability in the UK**. The metrics below are what she needs to steer on. Each area is tagged with where it lives:

- **Live**: real-time view or alert in the CMA (manager and supervisor)
- **Agent**: per-agent view for manager, supervisor and the agent's own dashboard
- **Report**: weekly or trend reporting from Postgres / BigQuery
- **Data**: prerequisite in HubSpot or Aircall, not something the CMA builds

| # | Area | Where | Sources |
|---|------|-------|---------|
| 1 | Conversion and speed to lead | Report, Live | HubSpot, Aircall, CMA |
| 2 | Indirect sales | Report, Agent | Shopify (via HubSpot), HubSpot |
| 3 | Reviews | Report, Live | Review platform (to decide), HubSpot |
| 4 | Churn and contract length | Report | HubSpot, Shopify / Juo |
| 5 | Reasons for not buying | Report, Agent | HubSpot |
| 6 | Complaints and vulnerability (UK) | Live, Report | HubSpot tickets and contacts |
| 7 | Productivity per agent | Agent, Live | Aircall, HubSpot |
| 8 | Effectiveness per agent | Agent | Aircall, HubSpot |
| 9 | Live monitoring | Live | Aircall, HubSpot, CMA |
| 10 | Quality monitoring | Agent, Report | Aircall AI, HubSpot, CMA |
| 11 | Data first | Data | HubSpot, Aircall |

### 1. Conversion and speed to lead
- Leads per day per country and source, excluding test deals.
- Speed to lead within office hours: median, % within 1 hour, % called before 12:00 the next working day.
- Open leads (not called, not ordered, not closed) per country and day of entry.
- Reach rate per attempt, attempts per lead.
- Lead to order: conversion rate and time to order.

The CMA's assignment, accept click and 5-minute rule (see Speed to lead) are the operational lever for these numbers; the assignment event log adds time to offer, time to accept and expiry rate per agent.

### 2. Indirect sales
- Orders linked to leads with order time: was there contact before the order, yes or no.
- A unique link per deal, so an order placed from a different email address still counts.
- Orders per agent.
- **Needs:** Shopify orders in HubSpot (order id, time, email, new or renewal).

### 3. Reviews
- Score and number of reviews per country per week.
- Reviews following deal stage 4.4 Completed Happy.
- Negative review flagged within one day (live alert).

### 4. Churn and contract length
- Cancellations per country per week, with Cancellation Reason (task for Joshua is on the board).
- Cancellations before the minimum term, reported separately.
- Active contracts older than 12, 24 and 36 months.
- CCL confirmed vs. not confirmed, churn per cohort.

### 5. Reasons for not buying
- Closed Lost Reason per country, source, agent and week; top 3 per country.
- Closed Lost Reason mandatory. Garbage, Duplicate, Wrong Phone and Accidentally Signed Up count as data quality, not as lost sales.

### 6. Complaints and vulnerability (UK)
- Complaints per country: number, subject, time to resolve, still open.
- UK: vulnerable customers, type, follow-up, agreements kept. OPC and collections for vulnerable customers reported separately.
- Alert when a complaint or vulnerable case is open longer than 1 working day.
- **Needs:** vulnerability field on the contact, complaint as a ticket category.
- Vulnerability data is sensitive. Alerts in the CMA show case status and a link to HubSpot, not the customer's details. Handling is agreed with Yordi.

### 7. Productivity per agent
- Calls in and out per day per campaign, calls per hour.
- Talk time, available, break and wrap-up time (Aircall), alongside the CMA's own statuses and time clock.
- First and last call of the day.
- Tickets handled, tickets with an owner.

### 8. Effectiveness per agent
- % reached per campaign.
- Results: quotes, orders, CCL confirmed, OPC agreements, courtesy happy.
- Speed to lead, callbacks within 4 hours.
- Calls without outcome, calls without contact.

### 9. Live monitoring
- Missed calls not yet called back, with waiting time.
- New leads not called after 1 hour.
- Tickets about to breach the 4-hour SLA.
- Priority 1: quote requests and exchanges after a resuscitation.
- Who is calling, who is available, queue.

### 10. Quality monitoring
- Scorecard: 5 calls per agent per week.
- Aircall AI (transcript, sentiment, playbook results) to choose which calls to listen to.
- Tag accuracy check (for example: 119 of 237 courtesy calls landed on 4.6 Negative).
- UK: FCA check on calls about money, % checked per agent.
- First time right: reopened tickets, repeat contact within 7 days.
- Sample of email replies.
- Short satisfaction question after a call or closed ticket.
- Complaints about an agent, coaching agreements and score over time.

### 11. Data first
These are prerequisites in HubSpot and Aircall. Without them the metrics above are unreliable, so they run in parallel with the foundation work. For a future customer the same list becomes the onboarding checklist for their CRM and telephony.
- Outcome mandatory on every call; old values removed from the list (Busy, Connected, retired ids).
- Every call linked to a contact and a deal.
- Country and owner on every ticket.
- SLAs set up in HubSpot.
- No test deals in the live pipeline.
- Aircall opening hours equal to team hours (lines currently appear to close at 17:00).
- Returns and exchanges tracked in one system.

---

## Authentication

| Version | Approach | Condition |
|---------|----------|-----------|
| V1 | Simple login screen where the agent enters their external user id | Build and test only, with own team and test data. Not built for Pulse4all, which starts on V2 |
| V2 | Real login through the tenant's identity provider (Google Workspace, Microsoft, HubSpot OAuth or local accounts), identity passed securely | Required before the first real agent registers hours (Roadmap step 2). Pulse4all: Google Workspace through IAP |

Identity is matched on the external id in `app_user_external_id`, never on the email address, so a renamed address or the domain of someone's CRM seat does not matter.

**Pulse4all: Google Workspace through IAP** (decided 4 October 2026). Every Pulse4all user, Newco agents included, has a full pulse4all.com Google Workspace account. Two layers, one list:

- **Gate (IAP)** proves who the visitor is. During the build it admits only `cma@pulse4all.com`; at go-live it opens to `domain:pulse4all.com`
- **CMA (`app_user`)** decides who may work, with which role, employer and tenant. A pulse4all.com account without an active `app_user` row gets a "no access yet" page from the app. Nobody maintains a per-agent Google group
- The app verifies IAP's signed token (`x-goog-iap-jwt-assertion`) on every request and does not trust the plain identity headers. *Implemented 5 October 2026 in `web/src/proxy.ts` and `web/src/lib/auth/iap.ts`: ES256 against Google's IAP key set, issuer, audience, expiry and a future-issue check; the verified identity travels to the app in headers only the proxy can set, incoming copies are stripped; the token verifier (`web/verify/iap-token.mjs`) covers valid, missing, wrong audience, wrong issuer, expired, future issue, wrong signer and spoofed headers*
- The match key is the Google account's stable numeric id (IAP's `sub` claim is `accounts.google.com:<id>`; `iap.ts` strips the prefix and refuses any `sub` that is not that prefix plus digits), stored as system `google` in `app_user_external_id`; the email address is display only. The identity carries its provider (`google` behind IAP, `mock` in dev) in a third header only the proxy sets, `x-cma-identity-provider`, and the login looks up provider plus subject. In the app this is `findPrincipal(identity)` on the data interface (see API). In dev, where the web app runs behind Cloud Run IAM instead of IAP, the identity is a mock identity (provider `mock`) and the dev seed stores its subjects (`agent-one`, `agent-two`, `supervisor`, `manager`) under system `mock`, so a test subject can never match a real Google row. The subject is chosen per request: header `x-cma-mock-subject` (verifiers), or `?as=<subject>` once in the browser, which sets a cookie; an invalid subject is a 400, never a fallback. In iap mode the header, cookie and `?as=` are ignored. `agent-one` exists in two dev tenants on purpose and gets "no access yet" until a tenant picker exists
- People with a Google login are added per tenant with `db/09_seed_people_prod.sql`; each person reads their own id with `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" https://www.googleapis.com/oauth2/v3/userinfo` (the `sub` field). The ids are pasted into the Studio editor when running, never committed
- Suspending someone's Google account ends their access to the CMA at once; two-factor follows the Google Workspace policy
- This is Pulse4all's configuration. Another customer uses its own identity provider; the user list and external-id matching stay the same. Because a person may exist in two tenants, login includes a tenant lookup across tenants (`cma.find_tenants_for_identity`, a `SECURITY DEFINER` function owned by `cma_owner` that returns only tenant ids, migration 0002) and a tenant picker when more than one matches.

A HubSpot app card (UI extension) can be added as a convenience shortcut. App cards appear on CRM records (contact, deal, ticket), not as a fixed main-menu item, and availability depends on the HubSpot subscription. The CMA itself is the home base, not a sub-page of HubSpot.

---

## Roadmap

Each step is delivered as increments; every increment goes to production once it is verified in dev (see Release flow).

1. **Foundation.** Google Cloud projects, Cloud SQL Postgres (EU), access and security, tenant and role model in the schema. *Done 4 October 2026: dev infrastructure (3 Oct), migration 0001 verified in dev, prod project created and 0001 verified there (4 Oct).*
2. **Workspace V1: workday and hours.** The first screens at workspace.pulse4all.app: login, start and end the workday, own hours per day, week and month. Migration 0002 writes the time model fresh under the CMA conventions; the trial's agent UI source (`p4a-agent-ui-src.zip`: the My account panel, theme, building blocks, copy file) and its decisions are input. Desktop only (minimum 1280 px, keyboard-first), no offline mode. Needs no sync and no integrations. Login through Google Workspace and IAP (see Authentication). Before the first real agent uses it: the app's user check and IAP token verification, prod on dedicated core with high availability, heads-up to Yordi, then the gate opens from `cma@` to the pulse4all.com domain. *5 October 2026: `web/` scaffolded; My day (clock, end workday), My hours (today, week, month, custom range), No access yet and Log out live on mock data at workspace.pulse4all.app for the `cma@` group; IAP token verification real; Cloud Build pipeline and trigger; copy, theme, layout and token verifiers. Later on 5 October: migration 0002 (time model) run and verified in dev and prod; `db/` with all eight scripts in the repository. Evening of 5 October: the data layer on Postgres (`app_user` check, workday, hours) and the JSON API `/api/v1/me`, a private `cma-web` in dev, the API verifier (15 checks, provoked) against dev, prod switched to the database with Martin as the first person (manager); the screens now run on real data in prod. Remaining: Joshua and Finn in the people seed, the default status flags and the hours shown (Arno and Kira), heads-up to Yordi, prod high availability and `min-instances=1`, then the gate opens.*
3. **Sync.** Ingest API on Cloud Run with its service account as `cma_app` member and one key per tenant. HubSpot and Aircall adapters (Make scenarios) mapping into the canonical entities through the ingest API. BigQuery connection on `cma_read` with `bq_reader` (Joshua), BigQuery in the same region as Cloud SQL.
4. **Data first (in parallel).** The data prerequisites from the KPIs section in HubSpot and Aircall, plus Shopify orders into HubSpot. First KPI reports for Kira can run from BigQuery as soon as sync and clean data are in place, before the CMA UI exists.
5. **CMA V1 for Pulse4all subscriptions, rest of the slice.** Statuses (with flags), teams and sites, roster, skills; the scheduler for auto-logout.
6. **Speed to lead.** Assignment, push via the outbox, accept click, accept window and expiry, the event log, the CRM adapter action for owner assignment; choice of realtime service.
7. **Manager and analytics views.** Productivity, effectiveness, coverage, gamification, live and quality monitoring, and Kira's KPI dashboards.
8. **Copy to Pulse4all Invest.** Configuration only, in the same database: `create_tenant`, organisations, channels, skills, roles.
9. **First external customer.** New database, customer registry and migration runner, onboarding checklist derived from Data first, data processing agreement, and a second CRM or telephony adapter if that customer needs one.

Later modules follow the Target scope table.

---

## Out of scope

- **Post-call outcome logging.** Already handled in HubSpot and Aircall.
- **Callpit.** The earlier agent cockpit is parked; the CMA starts fresh.
- **The Neon/Netlify trial** (Workspace, agent UI, queue engine; see the AgentUI handover of 4 October 2026). It was concepting and testing, not production. Its UI source and decisions are input for the CMA; its code is not carried over as-is. The trial's Workspace schema and validated hours export are not available, so the hours export is rebuilt and re-validated against an anonymised copy of the Steam hours CSV.
- **Customer data in the UI.** The CMA steers people; customer work happens in HubSpot and Aircall.
- **Invoicing.** The CMA produces approved hours and outcomes per employer; invoices are made in NetSuite.
- **A second CRM or telephony adapter before there is a second customer.** Design for it, do not build it.
- **Self-serve platform (sign-up, billing) before the first external customer.**

---

## Decision log

| Date | Decision | Why |
|---|---|---|
| 3 Oct 2026 | The CMA is a CRM- and telephony-agnostic management layer: design for many, build for one; system names only as data values; canonical entities with an adapter per tenant | Every company on a CRM plus telephony has the same gap; these abstractions are cheap in the foundation and expensive later, while a second adapter is only built for a second customer |
| 3 Oct 2026 | One database per customer; business lines within a customer are tenants sharing that database with RLS; Pulse4all Subscriptions and Invest are one database | Hard separation between companies, simple analytics per customer, no schema per business line |
| 3 Oct 2026 | Every verified increment goes to production; dev is the sandbox for the next iteration; the prod project is created right after migration 0001, not before Sync | Learn from running software early; no big-bang launch |
| 3 Oct 2026 | Authentication V2 is the tenant's identity provider, not HubSpot OAuth by definition | A customer without HubSpot must be able to log in; identity already matches on external id |
| 3 Oct 2026 | Make writes through an ingest API on Cloud Run, never directly to Postgres | Make's outbound IPs are shared; the database stays closed |
| 3 Oct 2026 | Tenant = business line; no separate business-line table | The README already defines the separation boundary as the business line; the customer level is the database, so no grouping table is needed |
| 3 Oct 2026 | Shared schema with `tenant_id` and row-level security, context set per transaction (`app.tenant_id`, `app.user_id`, `app.actor_label`), composite foreign keys | Separation enforced in the database, fail closed; one schema to migrate and report on |
| 3 Oct 2026 | Three group roles (`cma_owner`, `cma_app`, `cma_readonly`); team logins default to reader and escalate with `SET ROLE` | Nobody works with owner rights by accident; everything stays under personal logins |
| 3 Oct 2026 | Readers (BigQuery, NocoDB) only see the `cma_read` views; analytics sees all tenants of the customer by default, a reader can be limited per login; hard separation for dashboards in BigQuery | `EXTERNAL_QUERY` cannot set a tenant per query; all tenants in a database belong to one customer; base tables can change freely; exposed columns are deliberate |
| 3 Oct 2026 | `bq_reader` is a password login, the one exception to IAM-only | BigQuery federated connections authenticate with username and password |
| 3 Oct 2026 | Audit log on every tenant-scoped table from the first migration, insert-only, with acting user and process | History that was not captured cannot be recovered; needed for pay corrections, disputes and compliance |
| 3 Oct 2026 | Customer contact channels are per-tenant configuration (`channel`); skills, routing, SLAs and metrics reference a channel key | Email, sms, whatsapp and chat join phone without schema changes |
| 3 Oct 2026 | Speed-to-lead steps are append-only timestamped events; the accept click stays mandatory | Confirmation is provable and reportable per agent |
| 3 Oct 2026 | Every CMA user has an employer (`organisation`) | Hours and results per employer for reconciliation with the call center partner |
| 3 Oct 2026 | Working title renamed to Contactcenter-Management-App; the abbreviation CMA and everything carrying it (project IDs, group, roles, secrets) stay | Channels are configuration and nothing assumes phone; "call center" in the title contradicted that. Still a working title: the product name is decided at Roadmap step 9 with Mark |
| 4 Oct 2026 | Customer configuration (tenants, organisations, channels) and dev test data live in separate seed scripts, not in the migration | The same migration runs unchanged in dev, prod and every customer database; test data can never reach prod by accident |
| 4 Oct 2026 | Prod starts on the same shared-core machine as dev; dedicated core with high availability before real data lands | Nothing to keep available while the database is empty; saves about €80 a month until real data flows; the switch is an instance edit with a short restart |
| 4 Oct 2026 | Every migration, seed and verify script runs under a personal IAM login; a guard refuses `postgres` unless `cma.emergency` is set | The 0001 seed in prod was applied via `postgres` under `cma_owner`; those audit rows stay as recorded (`actor_login = postgres`), the audit trail must name a person from now on, and the emergency path remains available on purpose |
| 4 Oct 2026 | The Neon/Netlify Workspace and agent UI were a trial; the permanent setup is the CMA on Cloud SQL and Cloud Run at workspace.pulse4all.app. Trial schema, designs and tests are ported under the CMA conventions, not copied | One foundation with tenants, RLS, audit and EU hosting; the trial proved the concepts |
| 4 Oct 2026 | Workday and hours (Roadmap step 2) come before Sync; Authentication V2, prod high availability and the heads-up to Yordi move forward with it | Hours need no integrations, and a working screen early beats weeks of backend without anything to use |
| 4 Oct 2026 | workspace.pulse4all.app runs through a global external Application Load Balancer with IAP in front of Cloud Run; DNS stays at IONOS with one A record | Cloud Run domain mapping is preview and not recommended for production; IAP keeps the site closed to anyone outside the team during the build |
| 4 Oct 2026 | Authentication V2 for Pulse4all is Google Workspace through IAP; the CMA's `app_user` is the single list of who may work; identity matched on the Google account id | Every user, Newco agents included, has a full pulse4all.com account: no extra login system or licence cost, offboarding follows the Google account. The V1 HubSpot-id screen is not built |
| 4 Oct 2026 | Code in the private GitHub repository `Pulse4all-com/cma`, owned by a Pulse4all organisation; builds in Cloud Build | Ownership independent of personal accounts; a later move to an EU-hosted Git service stays cheap. EU sovereignty of the code is revisited at Roadmap step 9 together with the rest of the stack |
| 4 Oct 2026 | The CMA is desktop only (minimum 1280 px, keyboard-first, dense UI scale) and has no offline mode | Agents work at office workstations; without internet calling stops too. Mobile views for managers would be a separate decision |
| 4 Oct 2026 | Migration 0002 is written fresh, not ported; the trial's UI source and decisions are input | The trial's Workspace schema was never kept as files; the port was a rewrite under CMA conventions anyway |
| 5 Oct 2026 | Web app stack: Next.js 16 (App Router, Node runtime, standalone server in a Docker image), TypeScript strict, Tailwind v4 with the Pulse4all tokens as CSS `@theme` variables and Tailwind's default palette removed | Current stable; the token file is the single place for brand values and lets the theme verifier prove that nothing off-palette renders |
| 5 Oct 2026 | The dense UI type scale and the proposed semantic colours from Pulse4all-Style.md (sections 3.3 and 2.3) are adopted as the CMA's standard; Montserrat ships with the app from the brand's variable font file | Operational screens need the dense scale; no font request leaves the browser. Any deviation is flagged to Mark per the style guide's change control |
| 5 Oct 2026 | Runtime modes fail closed: `CMA_AUTH_MODE` and `CMA_DATA_MODE` default to iap and api; mock must be switched on explicitly on the Cloud Run service | Nobody can forget to switch the mocks off before real data lands |
| 5 Oct 2026 | Identity and data are seams: `proxy.ts` sets the verified identity in request headers, `src/lib/data` is the only data entry point, and the `app_user` check (`findPrincipal`) belongs to the data layer | Screens never change when the API replaces the mock; the user list is data, so it follows the same swap |
| 5 Oct 2026 | An ended workday stays ended; the next workday starts at the next day's login. Resuming after an accidental end is a correction, not a button | Time data is append-only; IAP's silent re-login after log out must not open a new day by itself |
| 5 Oct 2026 | Log out is a plain form POST (`/logout/end`) that ends the workday and answers a relative 303 to `/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE` | A client-side redirect cannot follow IAP's cookie-clearing round trip; the absolute host behind the load balancer is the container's, not the public domain |
| 5 Oct 2026 | Every user has a time zone (mock: Europe/Madrid); calendar days and week boundaries follow it, instants are UTC on the wire | Newco works in Spain, Pulse4all in the Netherlands and Denmark; in Postgres this is a per-user setting with an organisation default |
| 5 Oct 2026 | Cloud Build runs as its own service account `cma-build` with the minimum roles; manual builds stage source in an EU bucket; first deploy of each pipeline change by hand before the trigger carries it | The default Cloud Build account is broader than needed; the EU-only policy refuses the default US staging bucket; a pipeline is proven once before it runs unattended |
| 5 Oct 2026 | Time writes go through database functions (`open_workday`, `set_status`, `end_workday`, `correct_time_event`); the workday header is derived from the events by `refresh_workday` | One write path with the rules in one place for the web app, the scheduler and later tools (Open principle); the API stays thin; impossible states are refused at the source |
| 5 Oct 2026 | Facts are append-only by privilege: `cma_app` cannot update or delete `time_event`; corrections are new rows with reason and approver, chained one per event | The database enforces the convention, not the application; a voided or replaced event stays visible for pay disputes |
| 5 Oct 2026 | Views are built as one unfiltered owner-only core per computation with a tenant-filtered face in `cma` and a `reader_sees` face in `cma_read`; `security_invoker` views are not used | An owner view bypasses RLS and a `security_invoker` view cannot sit under a `cma_read` owner view (the check falls through to the reader); one definition, two faces, both fail closed |
| 5 Oct 2026 | Status catalog per tenant with semantic flags (`is_working`, `is_productive`, `is_paid`, `is_billable`, `is_default`), seeded with a default ladder for every tenant | Billing, adherence and hours depend on flags, never on a status name; the flags are tenant configuration, changing them is an update, not a migration |
| 5 Oct 2026 | A forgotten clock-out stays open, is flagged `needs_correction` and its hours are capped at the end of its business day; a manager closes it through a correction, later the scheduler | Nothing is invented: the end time is unknown, so the row says so until a person or the scheduler decides |
| 5 Oct 2026 | The Google account id is stored as the bare numeric id; dev test identities use system `mock`, not `google` | The numeric id is what Google's APIs return and what the prod people seed will carry; a mock subject can never match or impersonate a real Google row |
| 5 Oct 2026 | Verify scripts prove behaviour in prod too: blocks create throwaway users inside a rolled-back transaction instead of depending on seeded people | Prod has no people before the first agent hours; structure alone is not a verification |
| 5 Oct 2026 | `db/` numbering continues `05`, `06`, `07` per increment; `records/<migration>-<env>-<date>` is reserved for migration verify output, the web app's screenshots go to `records/web-<env>-<date>` | The folder name tells which increment a record proves; the earlier `0002-prod` web screenshots were renamed on 5 October |
| 5 Oct 2026 | The web app reaches Postgres in-process through `src/lib/data`, not through its own HTTP API; the ingest API for Make is a separate Cloud Run service (Roadmap step 3) | Route handlers for the screens would add a hop, a second authorisation check and a public URL for a caller in the same process; the ingest API has another caller, identity and ingress |
| 5 Oct 2026 | `cma-web` connects with the Cloud SQL Node.js connector and automatic IAM database authentication; its service account is the database user, member of `cma_app` with inheritance and without `SET ROLE` | No password exists to leak or rotate; the audit log's session user names the service; the database stays closed to IP addresses |
| 5 Oct 2026 | Own data is enforced through `cma.current_user_id()` in every query, never through an id passed to the query; the database clock decides; today is computed in SQL in the user's zone | A bug that hands over a colleague's id still cannot read their hours; nobody can backdate a start through the app; the app server's zone never matters |
| 5 Oct 2026 | The identity carries its provider; IAP's subject is stored and matched as the bare numeric Google id, a non-Google `sub` is refused | Another identity provider is another value, not a code path; the prod people seed carries the id `userinfo` returns |
| 5 Oct 2026 | An identity matching several tenants gets "no access yet" until a tenant picker exists; so does a user without a role | Never guess a tenant; a person without a role may not work yet |
| 5 Oct 2026 | A versioned JSON API under `/api/v1/me` (me, day, end, hours) behind the same gate; POST guarded by a custom header and `Sec-Fetch-Site` | Verifiers compare data instead of HTML; first piece of the Open principle; IAP sends its session with any request, so a write needs a cross-site guard |
| 5 Oct 2026 | Dev runs the image Cloud Build made for prod, by tag; dev's Cloud Run service agent may read the `cma` repository in prod | Dev tests exactly the bytes prod gets; no second pipeline that could drift |
| 5 Oct 2026 | `cloudbuild.yaml` and the trigger's substitutions are the one place `cma-web` is configured, including the database settings and at most 4 instances; the build stops before deploying when api mode lacks database settings | `--set-env-vars` replaces everything on each deploy, so hand edits vanish; 4 instances × pool 5 stays well under the instance's 50 connections; a misconfigured prod never gets deployed |
| 5 Oct 2026 | Prod switched to `CMA_DATA_MODE=api`; Martin, Joshua and Finn get role `manager` in prod for now | The team builds and tests everything; nobody else is in prod yet, so the extra rights reach nobody. Separating builders from call center management is revisited before agents join |
| 5 Oct 2026 | Google account ids never go into the repository; `db/09_seed_people_prod.sql` holds placeholders filled in only in the Studio editor | A Google account id is a personal identifier |
| 5 Oct 2026 | Code changes are made in a Cloud Shell clone: branch, `npm run build` with the repository's settings on Node 22, verifiers, pull request with `gh`, squash merge | The first red build of the day surfaced only in Cloud Build after the merge; the real build now runs before anything reaches `main`, which deploys to prod |

---

## Open decisions

- Per customer: a separate Cloud SQL instance or project, or a separate database on a shared instance (IAM users and the superuser are instance-level, so instance or project per customer is the stronger boundary); decide at the first external customer.
- Timing of the heads-up to Yordi and of prod high availability: both were set before real data lands, and since 5 October prod holds the team's own working time. Proposal: send the heads-up now; keep shared core for team-only use and switch to dedicated core with high availability before the first agent hours.
- Tenant picker: needed before anyone works for two tenants (in dev `agent-one` shows the refusal); a screen after login, or a default tenant per person.
- Roles in prod: the team has `manager` while building; whether builders and call center management get separate roles (an `admin` role on the ladder) before agents join, with Arno and Kira.
- `min-instances=1` on `cma-web` before agents use it (a few euros a month); keep at 0 while only the team tests.
- Hours registration and employment status: Wet DBA if Newco agents are freelancers, and Spain's daily working-time registration duty (whether the CMA becomes that record, retention); with Yordi and Arno before real use.
- Copy language of the Workspace for multilingual Newco agents: English and Dutch exist in `web/src/lib/copy.ts`, default English via `CMA_DEFAULT_LOCALE`; whether it becomes a per-user setting (with Kira).
- Forgotten clock-outs: migration 0002 leaves the day open, flags it and caps its hours at the end of the business day; a manager closes it with a correction. Still open: the scheduler's rule once Sync runs (roster end time, last Aircall or HubSpot activity).
- Default status flags (paid break, billable training and meetings, unpaid lunch) and which hours the agent's screen shows (working, as built, or paid): confirm with Arno and Kira before real hours; a change is an update on `work_status`, not a migration.
- Dev identities as system `mock` with a subject switch per request for two-user tests: decided for dev; to revisit if Cloud Run's direct IAP integration lets dev run with real Google identities without a load balancer (check when the first real agent is in dev).
- Parallel run against the Steam Connect hours export before Steam is switched off for hours.
- Product and legal setup for offering the CMA to other companies: Pulse4all product or separate entity, naming, where the Google Cloud folder lives, processor role and data processing agreement per customer (with Yordi and Mark).
- Competitive check against workforce-management tools that integrate with Aircall (Assembled, Playvox, injixo, Surfboard) before the external pitch.
- Assignment tie-breaker when several agents are available (longest idle, fewest leads today, round robin?).
- What happens when no matching agent is available (queue, fallback skill, notify manager?).
- Whether an agent who lets a lead expire is automatically set to an "away" status.
- Can one person work for two business lines on the same day, and if so where does the time clock live (today: one user and one clock per tenant).
- Default role ladder and permissions: confirm the seed with Arno and Kira.
- Owner of customer contact details: Shopify or customer portal.
- Shared mailbox: agreement that customer mail goes through HubSpot, which depends on making attachments as easy in HubSpot as in Gmail. Also how to attribute replies to individual agents.
- Choice of realtime push service: managed (Pusher Channels, Ably; check EU data residency and pricing) vs self-hosted (Centrifugo on Cloud Run) vs custom WebSocket service. Decide in Roadmap step 6.
- Scheduler: Cloud Scheduler with a Cloud Run job, or pg_cron on Cloud SQL (check availability for PostgreSQL 18).
- HubSpot subscription check for UI extensions and OAuth.
- NetSuite connectivity (Make module vs. direct API).
- Plan B for agents if the CMA is down.
- Source of review data per country and how it links to deals.
- Office hours per country, used for speed-to-lead and SLA calculations.
- Handling of UK vulnerability data in Postgres and in CMA alerts (with Yordi).
- Retention of staff data and the audit log; employee monitoring rules in NL and Spain; quiet hours for notifications (with Yordi).
- Cloud SQL's Knowledge Catalog integration (on by default on both instances, shares schema metadata only, not data): keep or switch off (with Yordi).
- Which Aircall AI features (transcripts, sentiment, playbooks) are in the current Aircall plan.
- Tool for the short satisfaction question after a call or ticket.

*Last updated 5 October 2026 (late evening): the API. The web app reads and writes Postgres in-process through the Cloud SQL connector with IAM authentication; JSON API `/api/v1/me`; identity with provider and the bare Google id; a private `cma-web` in dev with mock identities and the API verifier (15 checks, provoked); prod on the database since the evening, Martin seeded as the first person; build configuration from the trigger with a fail-closed check and at most 4 instances; the Cloud Shell workflow for code changes. Earlier the same day: migration 0002 in dev and prod, and the web app on mock data with Cloud Build.*
