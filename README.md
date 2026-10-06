# Contactcenter-Management-App (CMA)

The Contactcenter-Management-App (CMA) is a standalone application for running a contact center that works on a **CRM plus a telephony tool**. That setup is everywhere (HubSpot, Zoho, ActiveCampaign, … with Aircall, another softphone or the CRM's own calling), and none of those tools manage the people doing the work or make them fast: who is clocked in, who covers which skill, who gets the next lead, what the agent should do next, how productive the team is. The CMA is that missing layer: the workforce, productivity and management layer on top of CRM plus phone. Agents log in to start their day and work from one directive screen that serves them the next task; managers plan and steer their team; leads are routed to the right available agent within seconds.

Built first for Pulse4all AED subscriptions (HubSpot + Aircall), then copied to Pulse4all Invest, then offered to other companies. Agents and managers use it at **workspace.pulse4all.app**.

**Setup in one line:** front = the Workspace; backend = PostgreSQL on Cloud SQL, the CRM, Aircall, Make and n8n, all on Cloud Run in the EU.

**Where this goes:** one point where everything about the operation comes together in the Workspace: the agent's next task, the team's day, and reporting for every management layer built from all sources (CRM, telephony, Shopify, NetSuite, email, SMS, chat, the Customer App, the Asset Management Database) joined to the staff data only the CMA has. The version in which all sources are connected is the convergence version; its number is set when the roadmap beyond step 11 is cut (see Roadmap, Convergence).

**Team:** Martin, Joshua, Finn
**Key stakeholders:** Arno (call center manager), Kira, Peter, Bas (dashboards and reporting), Yordi (compliance and data protection)

---

## What we are building, in plain words

**At a birthday party:** "We make the operating system for a sales and service team that already has a CRM and a phone system. It hands every agent their next call, keeps the clock, and shows management who's productive and which customers stay." If they are still listening: "Think air traffic control for a call center." In the trade: a workforce, productivity and management layer on top of CRM plus telephony, CRM-agnostic. The product name is decided at Roadmap step 11 with Mark; this descriptor can be used now.

**Why we believe it works** (assessment of 6 October 2026, to be revisited with the business case below):

- **Technically doable.** Nothing in it is exotic: Postgres with row-level security, Cloud Run, Next.js, webhooks, a work queue on `FOR UPDATE SKIP LOCKED`, an outbox. The AgentUI trial proved the hardest algorithmic piece and closed its concurrency gaps; the demo proved the screens. The difficulty is elsewhere: the two-way sync with HubSpot (rate limits, idempotency, conflicts), upstream data quality (the Data first list is longer than the code), the long tail of sources in the convergence version, and the abstraction tax of staying universal while shipping for one customer. With three people and AI-assisted development the control layer is weeks, the desk is months, convergence a year or more. The risk is scope, not feasibility.
- **Value and ROI.** Positive internally if two things hold, both measured from day one (see Business case): the desk gets adopted and lifts talk time per paid hour, and speed to lead plus kept callbacks turn into conversions that leak today. The management layer alone has softer returns: correct hours per employer, fewer disputes, compliance, steering for Kira and Peter. Cloud cost is modest; the team's time is the real cost. The external roll-out is upside and is never counted in the business case.
- **AI agents will take a growing share of the calls; the need stands.** Hand-entered dispositions and scripted screens will fade as AI fills forms and infers outcomes from transcripts. What stays is the layer underneath: the system of record for work (who did what, when, for which customer, with what outcome), the queue that serves tasks, the reporting that joins outcomes to time and cost, and the compliance trail that AFM, FCA and GDPR demand from humans and machines alike. A work queue does not care whether the worker is a person or an AI agent; `app_user` gets a worker kind when the first AI agent works a queue, and attribution and reporting carry over unchanged. Build API-first (Open principle) so AI tools consume the CMA rather than replace it.
- **Competition.** HubSpot and Aircall are not expected to be the main competitors: their focus is the CRM and the telephony, not an operating system for the team, and the cross-vendor join of channel events with clock, roster and employer is outside both. The competitive check (Open decisions) targets workforce-management tools and agent-desk vendors instead. AI makes competitors faster too, so the moat is operational knowledge and data, not code.

---

## Guiding principles

1. **Design for many, build for one.** Nothing Pulse4all-specific, HubSpot-specific or Aircall-specific is hardcoded. Markets, teams, skills, channels, statuses, campaigns, result codes, rules and thresholds are tenant configuration; the CRM and the telephony tool are adapters per tenant; system names appear only as data values. We build the Pulse4all version first and add a second adapter *type* when there is a second customer, not before. Being CRM-agnostic is not a future option but a V1 fact: Pulse4all alone runs a separate HubSpot portal and Aircall account per business line (Subs, Invest, later US), so every adapter is configured per tenant with its own credentials, ids and mappings from the first increment.
2. **Open.** The data layer is accessible to other applications through an API, so others can read from it, write to it and build on top of it.
3. **Right the first time.** Isolation per customer, multi-tenancy (data strictly separated per business line), roles and permissions, and a change history are part of the foundation from the first table, not added later.
4. **Step by step, straight to production.** Build one working piece in dev, verify it, promote it to production, then start the next piece in dev. Production runs from the first increment; we never build the whole platform first. Always take the clean choice over the quick shortcut.
5. **Use the right tool for each job.** Don't force one system to do everything.
6. **Universal by default (development rule, 6 October 2026).** Every feature is built as if a second organisation with another CRM and Aircall starts tomorrow, even if that roll-out never happens. Pulse4all is tenant 1 and seed data, never code. Anything a tenant could want differently is configuration; anything vendor-specific sits behind an adapter interface.
7. **Postgres is the operational core.** Customer facts are owned by the CRM; the work itself (tasks, time, rosters, messages, outcomes, productivity) lives in Postgres on Cloud SQL. We never squeeze the operation into the CRM, and the CRM is never a dependency for an agent to keep working.

---

## Why standalone and not inside the CRM

HubSpot stays our CRM and the source of truth for contacts, leads, deals, tickets and owners. The CMA is deliberately built **outside** HubSpot, on its own foundation. We looked at building it inside HubSpot and decided against it for these reasons:

1. **This is not CRM work.** A time clock that starts on login, work statuses, rosters with skill coverage, automatic logout on the scheduled end time, realtime messages to agents and gamification are workforce and call center functions. HubSpot is not designed for them. Building them inside HubSpot means forcing them into custom objects and workarounds that stay fragile and limited.
2. **Live, all-day use needs a fast database.** Every agent keeps the CMA open all day, and managers watch live views. Running that directly on HubSpot hits API rate limits and slows down. Postgres is built for many concurrent reads and writes and handles hundreds of thousands of rows without effort.
3. **We combine more than HubSpot.** Aircall calls and recordings, the shared Gmail mailbox and later Shopify, the customer portal and NetSuite all feed productivity and steering. A neutral data layer brings these together; HubSpot would only see its own part.
4. **We own the data and the logic.** Time registration affects pay and labour rules and needs a complete, reliable history under our control. Our own Postgres plus BigQuery gives us that, plus open APIs for other tools to build on.
5. **Reusable across business lines and companies.** Built once and configured per tenant, the same CMA runs for Subscriptions and for Invest, and for another company on another CRM, without rebuilding it in each setup.
6. **Cost and flexibility.** The HubSpot features needed to stretch this far (custom objects at scale, advanced developer features) sit in the most expensive tiers, and we would still be limited by what HubSpot allows. A custom build costs effort up front but removes that ceiling.
7. **A directive work queue needs its own engine.** Agent productivity dropped when Pulse4all moved from Steam Connect to HubSpot with the Aircall plugin: agents choose their next task from lists instead of being served it. HubSpot's task queues are owner-based, have no leasing and cannot share a pool between agents safely. The CMA's queue engine serves the next task, leases it, retries it, closes it at the ceiling and never forgets it; HubSpot receives the outcome (decided 6 October 2026).
8. **Several CRM instances, one operation.** Pulse4all Subs and Pulse4all Invest each run their own HubSpot portal and their own Aircall account, and Pulse4all US will most likely do the same. No portal can see another portal. The one place where the whole operation comes together, people, hours, work and outcomes across business lines, has to sit outside all of them. That is the CMA: one application, one database per customer, one adapter instance per tenant, aggregation on top (decided 6 October 2026).

HubSpot remains fully part of the flow: contacts, deals and tickets live there, outcomes and field changes are written back there, and a HubSpot app card can serve as a shortcut to the CMA. Agents either do their customer work in HubSpot and Aircall, or, once the agent desk exists, in the CMA with the record read from HubSpot. The same reasoning holds for Zoho, ActiveCampaign or any other CRM a customer runs.

---

## Customers, databases and tenants

Separation has two levels.

| Level | What it is | Separation | Example |
|---|---|---|---|
| Customer | one company (or group) that uses the CMA | its own database, logins, secrets and readers | Pulse4all |
| Tenant | one business line within a customer | `tenant_id` and row-level security inside the customer's database | Pulse4all Subscriptions, Pulse4all Invest |

- Pulse4all Subscriptions and Pulse4all Invest are two tenants in **one** database; Pulse4all US is the expected third. Each tenant has its **own CRM and telephony instance** (its own HubSpot portal and Aircall account), connected through its own adapter instance with its own credentials, external ids and property and pipeline mappings. A person who works for two business lines is two users with two sets of external ids.
- **Aggregation across tenants** happens at the customer level, in `cma_read` and BigQuery (readers see all tenants of a customer by default) and, for management views in the Workspace, through customer-level reporting views; the operational tables and the agent desk stay strictly per tenant. Matching the same customer across portals (a Subs customer who is also an investor) is a purpose-limitation question for Yordi before it is built.
- **Regions.** The EU-only policy on the folder means a US tenant's data would live in europe-west4 as well; whether Pulse4all US needs a US region (and therefore its own customer database and project) is decided when US is set up.
- Every new customer gets a **new** database. Nothing in one customer's database can see another customer, so analytics on a database may see all tenants of that customer by default.
- The same migrations run in every customer database. From the second customer on, a customer registry and a migration runner (control plane) are needed; until then it is one database and a checklist.
- Whether a customer gets its own Cloud SQL instance or project, or a separate database on a shared instance, is decided at the first external customer (see Open decisions). IAM database users and the superuser are instance-level, so instance or project per customer is the stronger boundary.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  Workspace (Cloud Run, EU)                                         │
│  Agent desk: next task · record · softphone · one-press outcome    │
│  Management: Live · Report · Data (roster, team, configuration)    │
└──────────────┬────────────────────────────────┬────────────────────┘
               │                                │
               ▼                                ▼
┌──────────────────────────────┐   ┌────────────────────────────────┐
│  Postgres (Cloud SQL, EU)    │   │  Realtime push service         │
│  one database per customer   │   │  (push to agents, chat)        │
│  cma: operational tables     │   └────────────────────────────────┘
│   time · roster · skills ·   │   ┌────────────────────────────────┐
│   queue · attempts · messages│   │  Scheduler / worker            │
│   · mirror of CRM and calls  │   │  (lease expiry, lead expiry,   │
│  cma_read: reporting views   │   │   auto-close, period close)    │
└───────┬───────────┬──────────┘   └────────────────────────────────┘
        │           │              ┌────────────────────────────────┐
        │           └──► cma_read ─┤  BigQuery (analytics)          │
        │                          │  NocoDB (read-only)            │
        ▼                          └────────────────────────────────┘
   Ingest API (Cloud Run): canonical entities in
   Outbox worker (Cloud Run): actions out, one row per action
        ▲                 │
        │                 ▼
   Adapters per tenant: CRM · telephony  (Make and n8n scenarios today)
        ▲                 │
        │                 ▼
┌────────────────────────────────────────────────────────────────────┐
│  SOURCES AND TARGETS: CRM (HubSpot) · telephony (Aircall)          │
│  · Gmail (team@pulse4all.com) · SMS · chat · Customer App          │
│  later: Shopify · NetSuite · Asset Management Database             │
└────────────────────────────────────────────────────────────────────┘
```

**Layers**

- **Sources and targets.** Per tenant a CRM and a telephony tool, plus every other channel and data source that feeds the operation and its reporting. For Pulse4all: HubSpot (CRM: contacts, leads, deals, tickets, owners) and Aircall (calls, recordings, phone numbers) are the starting systems; the shared Gmail mailbox, SMS, chat and the **Customer App** (self-service: orders, address and contract changes, service requests, in-app messages) are channels, each a row in `channel`; Shopify and Juo (orders, subscriptions), NetSuite (invoices, payments) and the **Asset Management Database** (devices, installations, service status, battery and pad expiry, replacements) are data sources that feed cohort attributes and generate work for agents. The CRM is also a target: outcomes, field changes and owner assignments are written back to it. Sources are connected one by one along the roadmap; the model is built for all of them from the start.
- **Adapters and the canonical model.** Postgres stores canonical entities (lead, deal, call, ticket, owner, contact reference) with a fixed shape plus `source_system`, `source_id`, `synced_at` and the original payload in `raw`. An adapter maps one source system into that shape and executes the actions the CMA issues from its outbox. An adapter runs as one *instance per tenant*, holding that tenant's credentials, portal or account id, webhook secrets and field, pipeline and owner mappings: Pulse4all's three HubSpot portals are three instances of the one HubSpot adapter, its three Aircall accounts three instances of the Aircall adapter. A second CRM is a second adapter type with the same interface. The CRM adapter interface is small and fixed: resolve a phone number to a record, read a record, write a field diff, write an engagement with a result code, assign an owner, receive new tasks. The telephony adapter: embed the softphone, start a call, receive call events and recordings, read and set the agent's availability. Every source also maps into one more canonical entity, the **activity event** (source system, source id, channel, actor resolved through `app_user_external_id`, `occurred_at`, outcome reference, customer and cohort references): calls, dispositions, emails sent, chats and SMS handled, tickets closed, app interactions and lead assignments are all rows of this shape. It is the universal join between what happened in a channel and who was on the clock when it happened (see Features 5). HubSpot and Aircall are the first implementations; today the adapters are Make scenarios, n8n on Cloud Run EU is the second automation runtime; a second CRM is a second mapping, not a schema change. The ingest API contract is written against the canonical entities, never against a vendor payload.
- **Ingest API (Cloud Run).** The only write path from outside Google Cloud. Make, n8n and later other tools call it over HTTPS with a key per tenant; the key identifies the customer database and the tenant. It writes to Postgres through the Cloud SQL connector under its own service account. The database is never opened to external IP addresses. Decided 3 October 2026, over a direct Make connection, because Make's outbound IPs are shared with all Make customers in a zone; the same rule applies to n8n (6 October 2026).
- **Outbox worker.** Every action towards another system (write a field diff or an engagement to the CRM, assign an owner, send a product email, push a message) is a row written in the same transaction as the fact that caused it, then delivered by a worker with claim, in-flight, sent and failed states, retries and a `needs_review` parking state that needs a named person. Nothing in an agent's render path waits on an integration; the agent only ever sees a failed dial. Ported from the AgentUI trial's design.
- **Postgres on Google Cloud SQL (europe-west4).** The stable, fast foundation, one database per customer, in two schemas. `cma` holds the operational tables: tenants, people, roles, teams, skills, channels, statuses, time entries, rosters, messages, the work queue (campaigns, tasks, leases, attempts, callbacks, result codes), assignments, the mirror of CRM and call data, each with its change history. `cma_read` holds read-only reporting views and is the only thing readers ever see. Chosen over Airtable for volume (500k+ rows), stability and concurrent access from multiple points.
- **Mirror of customer data (6 October 2026).** Postgres holds a mirror of the customer fields the Workspace needs to serve a task: the CRM object ids, phone numbers in E.164 with an index, email, owner and the fields a campaign's field blocks declare. Nothing is mirrored because it might be useful later. The mirror is filled by the sync, read on open, and updated from the CRM's answer to a write, never from the agent's keystroke; a record deleted or anonymised in the CRM leaves the mirror through the sync. Which objects and fields are mirrored is tenant configuration behind the adapter. The mirror arrives with Sync (Roadmap step 3) and serves the screen pop and call matching before the agent desk exists.
- **Readers.** BigQuery (analytics, federated connection in europe-west4 or the EU multi-region, one connection per customer database) and later NocoDB (read-only table browser) read `cma_read` through their own login users, never the base tables, so tables can change without breaking either and every exposed column is a deliberate choice.
- **Realtime push service.** A separate, specialised service for pushing messages to agents in the open CMA, later also chat. Postgres stays the record of every message; the service only delivers (see Messaging). Kept outside Cloud SQL on purpose; choice of service still open. A 10-second poll on the open screen is the fallback for the first increment.
- **Scheduler / worker.** Time-based work: lease expiry, lead expiry after the accept window, automatic closing of forgotten workdays, period closing, later reforecasts. Cloud Scheduler with a Cloud Run job, or pg_cron on Cloud SQL; choice open.
- **Workspace (the CMA application).** The application agents and managers use all day, at workspace.pulse4all.app: one Next.js app with two surfaces on one foundation, the agent desk and the management side (Live, Report, Data). It talks only to Postgres (and the push service), never directly to every source; customer records are read from the mirror and refreshed live from the CRM through the adapter. It runs as a Cloud Run service in europe-west4 per project, with its own service account as `cma_app` member, connecting through the Cloud SQL Node.js connector with automatic IAM database authentication (no password anywhere). The screens reach Postgres in-process through the data layer; the same layer is exposed as a small JSON API under `/api/v1/me` (see API). Visitors reach it only through a global external Application Load Balancer with Identity-Aware Proxy (IAP) in front (see Web app and domain).

**Customer data.** Customer facts are owned by the CRM. Postgres holds the mirror described above and the synced canonical entities, so it falls under the same GDPR care Pulse4all already applies to HubSpot and Aircall (EU hosting, access control, retention that follows the CRM). The management screens show no customer data: alerts carry case status and a link. The agent desk shows the record it serves, read from the mirror and the CRM, and the audit log records who opened which record and when (who-saw-what), from the first desk increment. Staff data (names, work emails, time and performance history, the audit log) is personal data too and gets a retention rule. Real staff data reaches prod with the first agent hours (Roadmap step 2), before any synced customer data; Yordi gets the heads-up on the new data store before that, and a second heads-up before the mirror lands (Roadmap step 3). Since 5 October 2026 prod holds the team's own working time (the first real workdays, through the screens); agents' hours follow only after the conditions in Roadmap step 2. The dev environment holds test data only; real data, staff or synced, lands only in prod. When another company's data lands in a CMA database, Pulse4all becomes a processor for that company, which needs a data processing agreement per customer (see Open decisions).

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

**Code:** private GitHub repository `Pulse4all-com/cma` (organisation owned by Pulse4all; Martin's account is Pulse4all-DEV) with `README.md`, `db/` (the migration, seed, fixture and verify scripts, `00` to `09`, in the repository since 5 October 2026), `web/` (the application), `cloudbuild.yaml` and `records/` (verify output per migration and environment, for example `records/0002-dev-2026-10-05`; the web app's own screenshots live under `records/web-<env>-<date>`), and `docs/` (the runbook `docs/RUNBOOK.md` and dated analyses and design notes under `docs/analyses/`). `web/` is Next.js 16 (App Router, Turbopack, TypeScript strict), Tailwind v4 with the Pulse4all tokens in `src/app/globals.css`, Montserrat shipped with the app; screens import data only through `src/lib/data` and identity only through `src/lib/auth/identity`, both with a mock implementation chosen by environment, so the API replaces the mocks without touching a component. All copy is in `src/lib/copy.ts` (English and Dutch). The Postgres side lives in `src/lib/db/client.ts` (connector, pool, transaction-local tenant context, SQLSTATE translation), `src/lib/data/postgres.ts` (the `CmaData` implementation) and `src/lib/api/respond.ts` with `src/app/api/v1/me/**` (the JSON API). Verifiers in `web/verify/` (copy, theme, layout, IAP token, API), each with a `--provoke` mode that must fail; the API verifier runs against dev through the proxy and needs the dev fixture `db/08_fixture_api_verify_dev.sql`. `db/09_seed_people_prod.sql` adds people with a Google login per tenant; it holds placeholders, never real Google ids.

**Working on the code** (step by step in `docs/RUNBOOK.md`): from a clone in Cloud Shell (`~/cma`, logged in to GitHub with `gh` as Pulse4all-DEV, Node 22 through `nvm` to match the Docker image). Every change goes on a branch, passes `npm run build` with the repository's own TypeScript settings and its verifiers in Cloud Shell, then a pull request (`gh pr create`) and a squash merge. The real build runs before anything reaches `main`, which deploys to prod.

**Build and deploy:** Cloud Build in europe-west4, not GitHub Actions, so a later move to another Git host only changes the source setting. GitHub connection `cma-github` (Cloud Build repositories 2nd gen, authorised with the Pulse4all-DEV account, app installed on the Pulse4all-com organisation for `cma` only). Trigger `cma-web-main` runs `cloudbuild.yaml` on every push to `main` that touches `web/**` or `cloudbuild.yaml`: Docker build with the short SHA as version, push to Artifact Registry repository `cma` (europe-west4), `gcloud run deploy cma-web`. The build runs as service account `cma-build@p4a-cma-prod.iam.gserviceaccount.com` (Artifact Registry writer, Cloud Run admin, log writer, may act as `cma-web`), not the default Cloud Build account. Manual builds use `gcloud builds submit` with staging bucket `gs://p4a-cma-prod-build-src` (europe-west4; the default staging bucket is in the US and the EU-only folder policy refuses it). A build takes about two minutes on `E2_HIGHCPU_8`.

The deploy sets all of the service's environment variables at once (`--set-env-vars`), so `cloudbuild.yaml` and the trigger's substitutions are the one place `cma-web` is configured; a variable changed on the service by hand disappears at the next build. Substitutions: `_AUTH_MODE`, `_DATA_MODE`, `_IAP_AUDIENCE`, `_DB_INSTANCE`, `_DB_USER`, `_DB_NAME` (default `cma`), `_DB_POOL_MAX` (default 5), `_MAX_INSTANCES` (default 4); the file defaults to mock data. A first step, `check-config`, stops the build before anything is built or deployed when `_DATA_MODE=api` lacks `_DB_INSTANCE` or `_DB_USER`. The trigger is a 2nd-gen repository trigger: `gcloud builds triggers update github` refuses its substitutions (`INVALID_ARGUMENT`), so they are changed with `gcloud beta builds triggers export` → edit → `gcloud beta builds triggers import`, then `gcloud builds triggers run cma-web-main --branch=main`. Build status from the command line needs `--region=europe-west4`.

### Release flow: sandbox to production in small steps

- Dev is the sandbox, prod is live. Every increment that works and is verified in dev is promoted to prod; dev then moves on to the next iteration. Production exists from the first increment (migration 0001). We do not build the whole platform first and launch at the end.
- An increment ships with its migration, its verify script and a short release note. Promotion to prod: confirm point-in-time recovery is on (or take an on-demand backup), run the migration as `cma_owner` under a personal login, run the verify script, keep its output, then release the matching application or sync change.
- The verify output (screenshots or exported results) is kept per environment and date, for example `records/0001-dev-2026-10-04` and `records/0001-prod-2026-10-04`, next to the scripts in the repository.
- Migrations are forward-only and rerunnable. A mistake is fixed with a new migration, never by editing one that has shipped. From the second customer on, the same migration runs in every customer database.
- Prod holds real data from the first agent hours onward, dev never. Test data for a new feature lives in dev; a feature is only done when it is verified in prod.
- A verification is not verified until it has been made to fail on purpose (every verifier has a `--provoke` mode). Inherited from the AgentUI trial.

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
| `channel` | tenant | customer contact channels with an `is_synchronous` flag; phone and email today, sms, whatsapp, chat, the Customer App and more as rows later. Skills, routing rules, SLAs and metrics reference a channel, nothing assumes phone |
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
| `cma_app` | group | read and write on `cma` within the current tenant; insert-only on `audit_log` | ingest API service account (`cma-ingest@<project>.iam`); the CMA web app (`cma-web@<project>.iam`) |
| `cma_readonly` | group | SELECT on the `cma_read` views only, no rights on `cma`; sees all tenants of the customer unless the login user carries an `app.tenant_id` setting | `bq_reader`, later NocoDB readers; the team's own logins by default |
| `bq_reader` | login | BigQuery federated connection; the one password login, password in Secret Manager (`cma-<env>-bq-reader-password`), set via `gcloud sql users set-password` at Sync | |

Team members default to the reader view (the same surface BigQuery and NocoDB get), switch to `cma_owner` for migrations and to `cma_app` to test exactly what the application can see. Martin and Joshua hold ADMIN on the three roles, so Finn and service accounts are granted without using `postgres`. Each customer database has its own logins and secrets.

**Conventions for every migration**

- System names (hubspot, aircall, zoho, activecampaign, …) appear only as data values, never in table, column, function or role names
- Every migration starts with the personal-login guard and `set role cma_owner`, is rerunnable, and ships with its verify script, because it runs in dev, then in prod, later in every customer database
- Every script runs under a personal IAM login; `postgres` only for a declared emergency, so audit rows always name a person
- `timestamptz` everywhere; the business day is derived from the configured time zone (tenant now, site or market later)
- Facts such as time entries, attempts, lead assignments and notifications are append-only, with `occurred_at` (when it happened) and `recorded_at` (when we wrote it); a correction is a new row with reason and approver, and closed periods are locked
- Facts that affect pay, billing or reporting over time (employment, team membership, skills, rates, targets) carry `valid_from` and `valid_to` and are never overwritten
- Configurable catalogs carry semantic flags (paid, billable, productive, synchronous, outcome, sets do-not-call), never names only, so billing, adherence, SLAs and the queue never depend on a string match
- Synced data carries `source_system`, `source_id`, `synced_at` and the original payload in `raw`; ingest is idempotent on system and id
- Consequences carry their cause (`closed_by_task_id`, `dnc_set_by_task_id`, `supersedes_event_id`), so nothing self-repairs silently
- Every table that reporting needs gets its `cma_read` view in the same migration, with its columns listed explicitly
- `uuidv7()` primary keys; status columns instead of hard deletes

**Access rules**

- No authorized networks. Nothing connects directly; access only goes through the Cloud SQL Auth Proxy, Cloud SQL connectors or Cloud SQL Studio, with a Google login.
- Make, n8n and other external tools never connect directly; they go through the ingest API, and the CMA reaches them through the outbox.
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

**Display rules taken from the demo (6 October 2026, to confirm with Arno and Kira):** a status's colour is derived from its flags, never stored (working and productive → green, working but not productive → rose, not working → light blue); the shift belongs to the business day it started on; a change to an end time afterwards is always visible to the agent and the manager; Pulse4all's own fifteen statuses are seed data in `02_seed_pulse4all.sql`, with flags per status, once Arno confirms them.

### Planned migrations (order and content tentative)

| Migration | Holds | For |
|---|---|---|
| 0003 Teams and skills | `team` (markets, validity), `team_member`, `skill` with `dimension` (language, work_type, channel), `user_skill` with level and validity, level scales per dimension as tenant configuration | Roadmap step 5; My account details, Live board filters, message targeting, queue filters |
| 0004 Roster | roster, shift, absence type, coverage requirement per team and work type | Roadmap step 5 |
| 0005 Messaging | `message`, `message_delivery` (`delivered_at`, `read_at`, `acknowledged_at`), outbox | Roadmap step 6 |
| 0006 Mirror and outbox | canonical entities, the customer-field mirror with E.164 index, outbox with its states, adapter keys | Roadmap step 3 |
| 0007 Queue engine | `campaign` (queue model, field blocks, button keys, tools), `result_code` scoped by call type with outcome, priority, ceiling, retry interval and requirement flags, `task`, `lease`, `attempt`, `callback`, counters, `fn_serve_next` (`FOR UPDATE SKIP LOCKED`), `fn_book_disposition` (one transaction, idempotent on task), `fn_release_expired_leases`, `fn_queue_peek` | Roadmap step 7; ported from the AgentUI trial's verified design under CMA conventions |
| 0008 Assignments | lead assignment events (offered, delivered, seen, accepted, declined, expired, reassigned), accept window per tenant | Roadmap step 6 |

A correction that opens a past workday on behalf of another user (the "add a missed day" case) is a small addition to 0002's functions and ships with 0003.

---

### API: the web app's data layer (since 5 October 2026)

The web app reads and writes Postgres **in-process**: screens and route handlers call `data()` from `src/lib/data`, which returns the Postgres implementation when `CMA_DATA_MODE=api` and the in-memory mock otherwise. There is no HTTP hop between the screens and the database. The ingest API for Make and n8n (Roadmap step 3) is a separate Cloud Run service with its own service account and per-tenant keys; it can lift `src/lib/db/client.ts`.

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

**Planned routes** (same gate, same rules): `POST /api/v1/me/status` (set status; a non-working status chosen during a call takes effect at wrap-up), `GET /api/v1/call-context?phone=` (resolve a number through the mirror and read the record through the adapter; audited), `POST /api/v1/ingest/messages` and the other ingest routes on the separate ingest service, and the desk routes `next-task`, `book`, `search`, `lookup-by-number` once the queue engine exists.

**Verification.** `web/verify/api.mjs` runs 15 checks against dev with the dev fixture: identity in two tenants and unknown identity refused, tenant from the identity only, two users with two days, hours show the caller's own day, a `userId` parameter cannot redirect hours, the corrected forgotten clock-out leaves no past day open or capped, the end's request header and cross-site guard, end ends the own day, login after end does not reopen, a second end and a log out change nothing, the other user's day untouched, the 92-day bound. All pass; with `--provoke` all 15 fail. Records in `records/api-dev-2026-10-05`.

---

## Source of truth

Every data type has exactly one system that owns it. Postgres mirrors and combines; it does not overrule the owner. The rule of thumb since 6 October 2026: **customer facts are owned by the CRM, Postgres holds a mirror of the fields the Workspace needs; work facts live only in Postgres.** A result code and a call engagement go to the CRM because they are about the customer; a lease, a status interval, a roster shift, a message delivery or a productivity figure never does. The owners below are Pulse4all's; another customer fills in its own systems, the rule stays the same.

| Data | Owner (source of truth) |
|------|-------------------------|
| Contacts, companies, leads, deals, owner assignment | CRM (HubSpot); mirrored in Postgres for the fields the Workspace serves |
| Call facts: attempts placed, durations, talk time, recordings | Telephony (Aircall), through webhooks into Postgres; client-side events are a live hint, never the record |
| Work queue: campaigns, tasks, leases, attempts, dispositions (result codes), callbacks, counters, ceilings | CMA (Postgres); the CRM receives each outcome as an engagement with the result code in a custom property, and optionally a callback as a CRM task (tenant setting) |
| Result-code catalog, scoped by business line and call type | CMA (tenant configuration) |
| Support tickets | CRM (HubSpot) |
| Customer contact details (name, address) | To decide: Shopify or customer portal |
| Invoices, payment status, billing address | NetSuite |
| Orders (id, time, email, new or renewal) | Shopify, synced into HubSpot |
| Complaints, vulnerability, SLAs | CRM (HubSpot ticket category, contact field) |
| Call transcripts, sentiment, playbook results | Telephony AI (Aircall AI) |
| Customer App interactions: self-service orders and changes, service requests, in-app messages | Customer App, synced as activity events and tickets into the CRM where they need follow-up |
| Devices, installations, service status, battery and pad expiry, replacements | Asset Management Database (system and access to confirm) |
| Payments, days to pay, dunning stages | NetSuite |
| Subscriptions, terms, cancellations | Shopify and Juo, synced into HubSpot |
| Reviews | To decide: review platform |
| Agents, roles, teams, skills, rosters, statuses, time entries, lead assignments, quality scorecards, messages, change history | CMA (Postgres) |

**What is written back to the CRM:** field diffs the agent made on a served record, the engagement with the result code, do-not-call, owner assignment, and optionally callbacks as CRM tasks. Everything else stays in Postgres by default. Write-back goes through the outbox; the mirror is updated from the CRM's answer.

---

## Users and roles

| Role | Example | Sees and does |
|------|---------|---------------|
| Agent | Call center agents (mostly in Barcelona) | Own day: clock, status, roster, next task from the queue, messages, own hours and scores |
| Supervisor | Team lead | Their own group of agents, live status and performance, corrections for their team |
| Call center manager | Arno | Full operational environment: rosters, skill coverage, live team view, productivity, messaging, hours and export, team management |
| Admin | Builders, later a customer's own administrator | Configuration: statuses, teams, skills, campaigns, result codes, connections and API keys, user management for all roles; proposed 6 October 2026 from the demo's Admin versus Management split, to confirm with Arno and Kira |
| Analytics | Kira, Peter, Bas | Dashboards, KPIs and reporting. Kira (Head of Call Center) also uses live and quality monitoring, see KPIs section |

Roles and permissions are tenant-aware: every business line gets the same ladder with its own people. Reporting across business lines (Kira over Subs and Invest, finance over all three) is a customer-level reader role on `cma_read` and BigQuery, not a tenant role; how the Workspace shows a cross-tenant Report surface to such a person is an open decision (tenant picker with an "all business lines" view on reporting views only). Roles are rows per tenant, seeded from one default ladder and adjustable; the permissions they bundle come from a catalog defined by the application code. A grant can be scoped (a supervisor for one team, a manager for one market). Users are not only the customer's own employees: each user belongs to an organisation (the company itself, the call center partner, …), so hours and results can be reported per employer. The same person in two business lines is two users. A manager may edit agents; an admin may edit anyone (`users.manage_agents` versus `users.manage_all`). `app_user` gains a worker kind (person, AI agent) when the first AI agent works a queue; everything that attributes work and time to a user applies to both. A pulse4all.com account that reaches "no access yet" appears in Team as an access request a manager can grant a role and employer to; that is the demo's approval queue without the password.

**Teams and skills (decided 6 October 2026).** Three dimensions, all tenant configuration:

| Dimension | What it is | Shape | Used by |
|---|---|---|---|
| 0 Teams | Membership, not proficiency. Pulse4all: Team EN, Team NL, Team DE, Team FR, Team Nordics | `team` with one or more markets and validity; `team_member` with validity; an agent can be in several teams | Queue hard filter, Live board and roster grouping, message targeting, scope of a supervisor or manager grant |
| 1 Languages | Proficiency with a four-step scale: Basic, Good, Fluent, Native | `skill` with dimension `language`; `user_skill` with level and validity; the scale is tenant configuration | Queue filter with a minimum level per task, message targeting, coverage |
| 2 Work types | Sales, Operations, Debt, and whatever a tenant adds | `skill` with dimension `work_type`; binary for Pulse4all, levels allowed by configuration | Queue hard filter, roster coverage, productivity per work type |

A third skill dimension, channel (phone, email, chat), stays in the model as a dimension a tenant may leave empty. Nordics shows why team and language are separate: one team, several markets, and per agent Swedish Native, Danish Good. A task declares team, required language with minimum level and work type; eligibility is derived at serve time, no precomputed table (the AgentUI trial measured 2.6 ms for 5,000 queued tasks).

---

## Features

### 1. Workday and time tracking
- Logging in starts the agent's workday and the time clock; My day shows "Clocked in at login · 09:12" with one Clock out button, and under it a grid of status buttons with a timer since the last change (taken from the demo, 6 October 2026).
- Agents switch status during the day within the general clock-in and clock-out: available, break, lunch, training, meeting, and work on other projects or business lines (configurable list, each status flagged as working, productive, paid, billable). Non-working statuses stop the clock. A status can carry an activity code (Organisation module), so time on another project is reportable and billable separately from V1 without a new table. A non-working status chosen during a call takes effect at wrap-up (pause after this call).
- A status change also sets the agent's availability in the telephony tool through the adapter, with the mapping per status as tenant configuration (Lunch → Out for lunch, Available → Available, a work status → Back office or Available depending on whether calls should still ring). One action instead of two, and the phone stops ringing during a pause. Reading availability is confirmed in Aircall's API; whether it can be set per user, and on which plan, is verified before this is marked done. If it cannot, the Live board shows the mismatch (CMA says Lunch, phone says Available).
- A running status chip in the header on every screen; the browser title carries the unread count.
- If an agent forgets to log out, the day stays open, is flagged and capped at the end of its business day; a manager closes it with a correction, later the scheduler does (rule to decide once Sync runs). Whether the agent may propose the end time from a dialog, stored as a correction awaiting approval, is an open decision.
- Full history of every clock-in, clock-out and status change, append-only; corrections are new rows with reason and approver. Time data is the heart of the system and must be reliable. A corrected or afterwards-entered end time is visible as such to the agent and the manager.
- The shift belongs to the business day it started on.
- The CMA stays open all day (second screen) and lands on a page with the agent's day line (date, today's shift from the roster), messages, status panel and, once the desk exists, the next task.

### 2. Rostering (manager)
- Arno publishes rosters per team and market.
- Planner: agents by seven days, one structured shift per cell (start and end, or an absence type such as Off or Sick), quick typing (`9-17:30` normalises to `09:00–17:30`), Copy previous week, a dirty-state guard; agents see only their own row and their shift on My day and on the Live board (taken from the demo).
- Roster shows **skill coverage** per team per day: for example France on Tuesday, is sales covered, courtesy calls, outstanding payments, exchanges?
- One agent can hold many skills. An omniskilled agent covers multiple slots alone.
- Coverage shows not only *covered* but *how deeply covered*, so single-person dependencies are visible.

### 3. Teams and skills
- See Users and roles: teams (membership, markets), languages with a four-step level scale, work types, and channel as a dimension a tenant may leave empty. All lists and scales are configurable per tenant.
- Skills and teams drive rostering coverage, lead assignment, the work queue's eligibility and message targeting.
- Team shows each person's teams and skills; the Skills dialog sets a level per language and a yes or no per work type (from the demo).

### 4. Speed to lead
1. A lead comes in (through the sync, from the CRM or an ingest call).
2. The system finds agents who are **available** and have the **matching skills** in the right team.
3. The lead or deal is assigned to that agent as owner in the CRM, through the tenant's CRM adapter (HubSpot for Pulse4all).
4. The agent gets an immediate push message in the CMA.
5. The agent **must click to accept** the lead.
6. If not accepted within **5 minutes** (configurable per tenant), the lead moves to the next available agent.

Every step is logged as an append-only event with timestamps: offered, delivered to the agent's screen, seen, accepted or declined, expired, reassigned. Speed-to-lead reporting and the accept rule both run on this log. Once the agent desk exists, a new lead is also a task at the top of the queue, so the accepting agent's next served task is the lead.

### 5. Reporting and steering for every management layer
The reporting proposition of the product, and the buy-in for Kira and for Peter on Invest: the Workspace combines the CRM, telephony, Shopify and Juo, NetSuite, email, SMS, chat, the Customer App and the Asset Management Database with the staff data only the CMA has (clock, statuses, teams, skills, employer, roster). Every outcome is attributed to the agent who produced it and placed in the time interval they were on the clock. The human factor and the time factor from all channels, in one place, for every layer:

- **Supervisor:** the team today, who is on what, outcomes per agent per hour so far.
- **Manager:** productivity per agent per worked hour and per productive hour, benchmarking against the team median and the agent's own previous period, by channel, work type and campaign; sales and support work shown side by side so support-heavy agents are not misjudged; Prepare and Finish time per agent and campaign (the AgentUI trial's analysis found they consume most paid agent hours).
- **Head of call center:** Kira's KPIs (next section) with the staff dimension added: conversion per agent and team, speed to lead per agent, reasons for not buying per agent.
- **Business line owner and finance:** outcomes and cost per outcome per employer, team and work type (rates from the Billing module), approved hours, for Subs and for Invest.
- **Cohorts:** customers grouped by entry month, country, source or campaign, proposition, and the agent or team that converted them; per cohort how long they stay customer (retention curve, churn before and after the minimum term), how they pay (days to pay, late payments, dunning stages, collections outcomes), reviews, upsell and service events from the asset database. Agents form cohorts too: hired per month, ramp-up time to target productivity, retention. See KPIs section 12.

Rules: per worked or productive hour, never per calendar day; the first view is Total Calls Today per agent with talk time (from the Subs agent UI), fed by the Aircall sync; the join is designed now and filled source by source along the roadmap. What agents see of each other, and what the partner's HR sees, follows the employee-monitoring decision with Yordi.

### 6. Gamification (agent)
- Daily goals, scores, streaks and comparison with yesterday or colleagues, built from the same metrics the manager uses.
- Metrics must reward the right behaviour (not just volume, not just easy conversions).
- Whether agents see colleagues' call counts is decided with Arno before Total Calls Today is shown to agents.

### 7. Messaging
- Managers and supervisors push messages directly to agents in the open CMA; later 1:1 and team chat, announcements that must be acknowledged, and an assist request from agent to supervisor.
- Targets: everyone, a team, a language with a minimum level, a work type, or specific agents, optionally only those clocked in or Available right now (from the demo). Group targets are resolved into delivery rows at send time, so history stays exact when teams change and the read count always has a denominator.
- Every message is a row in Postgres with one delivery row per recipient (`delivered_at`, `read_at`, `acknowledged_at`). An urgent message opens a pop-up with a sound that the agent must confirm; confirming writes `acknowledged_at`, separate from reading.
- Pushing goes through an outbox: the application writes the message and the outbox row in one transaction, a relay forwards to the realtime service, acknowledgements flow back. Nothing is lost if the push service hiccups.
- Messages carry references (CRM id, case status, link), never customer data. Delivery respects quiet hours and working time; Spain has a statutory right to disconnect.
- Automations (Make, n8n) send messages through `POST /api/v1/ingest/messages` with the tenant's key; targets by team, skill name, CRM user id or email are resolved through `app_user_external_id` and the catalogs.
- Later channels for reaching users (email, mobile push) are extra delivery rows behind the same message.

### 8. Agent desk: the directive work screen (decided 6 October 2026)
The agent's working surface, Steam Connect-like, built so daily practice can show whether Newco needs it; the assumption is that it will.

- **Next task, served.** Clock in, press Next, the system serves the task that matters most for this agent: callback appointments first, then the priority matrix by call type and attempt, filtered by team, language level and work type. One screen, no list to browse, no choice of what to do next.
- **Queue models per campaign.** `owned` (agents own their records, no pool; Invest) and `shared` (team pool, callback appointments stay personal; Subs). Unassigned work on an owned campaign is refused at write time.
- **No task forgotten.** Every served task is leased; an expired lease returns to the pool. Callbacks return to the pool when the agent is absent on a shared campaign. A ticket closes automatically at its ceiling. Overdue work and unleased callbacks show on the Live board and in the queue counter (due, mine, pool, handled today, per period).
- **The record, read live.** The served record comes from the mirror and is refreshed from the CRM through the adapter; field blocks per campaign decide what is shown. Deep links open the record in the CRM and in other systems (Shopify, Bloqhouse). Edits become field diffs in the outbox.
- **One-press outcome.** A result code books in one press; a code that needs something (an objection, a memo, a deal amount, a callback moment) asks for exactly that. Booking is one transaction: attempt, memo, field diff, counters, next task or close, lease release, outbox rows, then the next task is already there. Never gated on call state.
- **Result codes** are a scoped catalog (business line, call type) with outcome, priority, ceiling, retry interval, requirement flags and side effects (do-not-call, email flow). Processors (product emails, request a quote) are actions, not codes, and still require a code afterwards.
- **Telephony embedded.** The Aircall softphone mounted in the desk, kept mounted all day; the agent's call phase (idle, dialing, ringing, on call, wrap-up) from SDK events as a live hint; call facts from webhooks. One-click dial through the telephony API (`POST /v1/users/:id/calls`) where the plan and the embedding allow it; staging the number in the dialpad otherwise. Incoming call: a screen pop with the number called and the CRM match.
- **Speed.** Keyboard for every action (1–9 and 0 for codes, letters for actions, F2 search), shortcuts suppressed while typing, prefilled memo, requirement-only dialogs, nothing in the render path waits on an integration. Search opens a record outside the queue and never steals the task.
- **Universal.** Campaigns, field blocks, button grids, result codes, queue model, ceilings and tools are tenant configuration; the Invest line's prospectus compliance is a campaign's compliance hook, not product code. Built for Subs first, Invest after.

### 9. Management screens (from the demo, 6 October 2026)
- **Live:** who is on which status right now, tiles per category, filters by team, skill and status, duration, clocked in, today's shift, on-call state from telephony; stale days flagged.
- **Dashboard:** time per status, hours per day, per agent, for a period; grows into the per-layer reports of Features 5 as sources connect.
- **Hours and export:** clock-in and clock-out per agent per day for payroll, pauses, note chips, two CSV exports (hours per day, status changes) with separator, decimal mark and date format as tenant settings; Correct a day and Add day on `correct_time_event` with a required reason.
- **Team:** access requests, roles, employer, teams and skills, disable and enable.
- **Configuration (admin):** status catalog with flags, teams, skill catalog and level scales, campaigns and result codes, connections and API keys for Make and n8n (create a connection, see the instructions once, rotate by creating a new one).

---

## Target scope beyond V1

The CMA covers everything needed to run the contact center besides the telephony itself (IVR, routing, recording stay in Aircall), the customer channels and the CRM. V1 builds the first slices (Roadmap steps 2 and 5 to 8); the foundation is designed so the rest can be added without reworking what exists.

| Module | Covers | Main users |
|---|---|---|
| Organisation | tenant settings, markets, office hours and holidays per market, sites and time zones, teams and hierarchy, employers, activity codes, skill and channel lists, roles, integrations and adapters (CRM, telephony), API keys, audit, retention | manager, admin |
| People and staffing | identity, employment history (employer, contract type, hours, start and end), skills with proficiency and validity, availability and preferences, onboarding and offboarding | manager, HR at the partner |
| Time and attendance | clock, statuses, breaks, adherence (planned vs actual), corrections with approval, timesheet approval and locked periods, leave and balances, overtime and rest rules | agent, supervisor, manager |
| Rostering | shift templates, roster versions and publication, coverage requirements per market, work type and channel per interval, swaps and requests, forecasting from historical volume, intraday reforecast | manager, supervisor, agent |
| Agent desk | the directive work screen: campaigns, queue models, next task, leases, result codes, callbacks, memo, embedded telephony, call context from the mirror, outbox write-back, scripts and templates per campaign, compliance hooks | agent, supervisor |
| Routing | the queue engine, assignment rules per tenant, market and channel, queues, accept and expiry events, fallback and escalation, full trail | system, agent, manager |
| Performance and quality | metric catalog with definitions, targets per role, team and period, scorecards as versioned forms, calibration, disputes, coaching and action plans, gamification | supervisor, manager, analytics, agent |
| Communication | push, broadcasts, must-acknowledge announcements, chat, assist requests, preferences and quiet hours, mobile push | everyone |
| Billing and cost | rates per employer, role and work type with validity, billable and paid flags, approved hours per period, outcome counts, exports; invoicing itself stays in NetSuite | manager, finance |
| Reporting | live views and wallboards, agent dashboards, reports for every management layer from the combined sources plus staff, agent benchmarking per worked hour, cost per outcome, cohort analysis (retention, payment behaviour, outcomes per entry cohort, agent cohorts), weekly and trend reports, as-of reporting (who was in which team, on which contract, on a given date) | all roles |
| Compliance | staff data under GDPR, retention per data type, employee monitoring rules in NL and Spain, right to disconnect, who-saw-what for sensitive alerts and for served records | Yordi, manager |
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
| 5 | Reasons for not buying | Report, Agent | HubSpot, CMA result codes |
| 6 | Complaints and vulnerability (UK) | Live, Report | HubSpot tickets and contacts |
| 7 | Productivity per agent | Agent, Live | Aircall, HubSpot, CMA |
| 8 | Effectiveness per agent | Agent | Aircall, HubSpot, CMA |
| 9 | Live monitoring | Live | Aircall, HubSpot, CMA |
| 10 | Quality monitoring | Agent, Report | Aircall AI, HubSpot, CMA |
| 11 | Data first | Data | HubSpot, Aircall, every connected source |
| 12 | Cohorts | Report | HubSpot, Shopify / Juo, NetSuite, Asset Management Database, CMA |

### 1. Conversion and speed to lead
- Leads per day per country and source, excluding test deals.
- Speed to lead within office hours: median, % within 1 hour, % called before 12:00 the next working day.
- Open leads (not called, not ordered, not closed) per country and day of entry.
- Reach rate per attempt, attempts per lead.
- Lead to order: conversion rate and time to order.

The CMA's assignment, accept click and 5-minute rule (see Speed to lead) are the operational lever for these numbers; the assignment event log adds time to offer, time to accept and expiry rate per agent. With the agent desk, attempts and result codes are CMA facts, so reach rate and attempts per lead come from the queue engine.

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
- Defined on the scoped result-code catalog (business line, call type, code), so Invest's Sleepnet is never counted as Subs' Nurturing.

### 6. Complaints and vulnerability (UK)
- Complaints per country: number, subject, time to resolve, still open.
- UK: vulnerable customers, type, follow-up, agreements kept. OPC and collections for vulnerable customers reported separately.
- Alert when a complaint or vulnerable case is open longer than 1 working day.
- **Needs:** vulnerability field on the contact, complaint as a ticket category.
- Vulnerability data is sensitive. Alerts in the CMA show case status and a link to HubSpot, not the customer's details; on the desk the flag shows only for GB records, as in the Subs agent UI. Handling is agreed with Yordi.

### 7. Productivity per agent
- Calls in and out per day per campaign, calls per hour.
- Talk time (`ended_at − answered_at`; Aircall's `duration` includes ring time), available, break and wrap-up time, alongside the CMA's own statuses and time clock.
- Prepare and Finish time: from a served task to the first dial, and from call end to the booked result.
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
- Who is calling, who is available, queue depth, overdue callbacks, expired leases.

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
These are prerequisites in HubSpot, Aircall and every source that joins later. Without them the metrics above are unreliable, so they run in parallel with the foundation work. For a future customer the same list becomes the onboarding checklist for their CRM, telephony and channels.
- Every channel event carries the agent's identity in that system and a timestamp, or it cannot be attributed: Aircall user, HubSpot owner, Gmail sender, chat and SMS agent id, Customer App handler. The shared mailbox attribution to individual agents (open decision) is the prerequisite for email productivity.
- Every customer-facing record carries the customer key the cohorts need: entry date, country, source or campaign, proposition, converting deal and owner; payments in NetSuite and devices in the asset database linked to that customer.
- Outcome mandatory on every call; old values removed from the list (Busy, Connected, retired ids). With the desk, the CMA's result code lands in a HubSpot custom property on every call engagement; until then agents log it in HubSpot.
- The Subs result-code catalog (semantics, priorities, retry intervals, do-not-call flags) confirmed by Kira before anything is seeded; the Subs codes collide with Invest's on the same numbers.
- Every call linked to a contact and a deal.
- Country and owner on every ticket.
- SLAs set up in HubSpot.
- No test deals in the live pipeline.
- Aircall opening hours equal to team hours (lines currently appear to close at 17:00).
- Aircall per-number settings (origin registration, call tagging, the native HubSpot integration on or off) on an add-a-number checklist.
- Returns and exchanges tracked in one system.

### 12. Cohorts
A cohort is a group of customers (or agents) that share an entry point; the report follows the group over time instead of reporting a period. Cohort definitions are tenant configuration in the metric catalog; Kira and Peter confirm Pulse4all's.
- **Customer cohorts** by entry month, country, source or campaign, proposition (Subs: HS1, FRx, Buurt AED; Invest: 10K, 100K), employer of the converting agent, converting agent or team.
- **How long they stay:** retention curve per cohort (active after 3, 6, 12, 24, 36 months), churn before and after the minimum term, cancellation reasons per cohort; the cohort view of KPI 4.
- **How they pay:** days to pay the first and later invoices, share paid on time, late payments and dunning stages, Open Payment call outcomes and collections results, write-offs; from NetSuite joined to the CRM customer.
- **How they behave:** reviews per cohort, complaints, Customer App use, service events and replacements from the asset database, upsell and extra devices.
- **What they cost and bring:** contact attempts and talk time per customer over their lifetime, cost per acquired customer per cohort, revenue per cohort (NetSuite).
- **Agent cohorts:** agents by hiring month and employer: ramp-up time to the team median, productivity and conversion over tenure, retention of agents; the human factor applied to the staff itself.
- **Needs:** the customer keys from Data first on every record, payments and subscriptions synced, the asset database connected; cohort reports run from BigQuery on `cma_read` and appear in the Workspace's Report surface.

---

## Business case and how we prove it

The CMA is justified by four effects: more talk time per paid hour, more conversions from leads and callbacks that are no longer late or forgotten, correct hours and cost per employer, and steering on cohorts rather than periods. Each effect has a KPI, a baseline taken before the related increment reaches agents, and a target to review after three months of use. Pulse4all's values are configuration; for a future customer the same table is the pilot scorecard.

| # | KPI | Definition | Baseline source (before) | Target after 3 months | Proves |
|---|---|---|---|---|---|
| 1 | Talk time per paid hour | Aircall talk time (`ended_at − answered_at`) ÷ paid seconds from `workday_summary`, per agent and team | Aircall export + Steam or current hours, 4 weeks before the desk | +20 % | Desk productivity |
| 2 | Prepare and Finish time per call | served task → first dial; call end → booked result, medians | AgentUI trial analysis; first measured by the desk itself | −30 % versus the first desk month | Desk productivity |
| 3 | Calls per productive hour | attempts ÷ productive seconds, per campaign | Aircall + current hours | +15 % | Desk productivity |
| 4 | Speed to lead | median time from lead creation to first attempt within office hours; % within 1 hour | HubSpot timestamps via BigQuery after Sync | median < 15 min, > 80 % within 1 hour | Routing and queue |
| 5 | Callbacks kept | % of callback appointments attempted within the promised window; missed callbacks per week | HubSpot tasks today (incomplete by nature) | > 95 %, missed < 2 per week | No task forgotten |
| 6 | Lead conversion per cohort | leads → orders per entry-month cohort, controlled for country and source | HubSpot via BigQuery | +10 % relative on comparable cohorts | Revenue effect |
| 7 | Hours disputes and corrections | disputes with the partner per month; corrected days ÷ worked days | Arno's current reconciliation | disputes → 0 per month, corrections < 2 % | Time model, billing |
| 8 | Reconciliation effort | hours from export to approved invoice basis, per month | Arno and finance, time spent today | −75 % | Billing module |
| 9 | Desk adoption | % of attempts booked through the desk; agent satisfaction (short monthly question) | n/a; measured from the first desk week | > 90 % of attempts; satisfaction ≥ 4 of 5 | Whether Newco needs the desk |
| 10 | Cost of the CMA | cloud cost per month; team days per increment | Budget alerts, release notes | cloud < €500 per month at Pulse4all scale | Cost side |

The ROI line, reviewed quarterly: paid hours × hourly rate × talk-time lift (KPI 1) + conversion delta × margin per order (KPI 6) + reconciliation hours saved (KPI 8), minus cloud and team cost (KPI 10). Baselines 1, 3, 5 and 7 can be taken now from Aircall exports, HubSpot and Arno's records; 4 and 6 need Sync and BigQuery (Roadmap steps 3 and 4), so taking them is part of Data first. The targets are proposals to confirm with Arno, Kira and Peter; a target that turns out wrong is changed in this table, not argued over later. Baseline values are filled in here once taken.

---

## Authentication

| Version | Approach | Condition |
|---------|----------|-----------|
| V1 | Simple login screen where the agent enters their external user id | Build and test only, with own team and test data. Not built for Pulse4all, which starts on V2 |
| V2 | Real login through the tenant's identity provider (Google Workspace, Microsoft, HubSpot OAuth or local accounts), identity passed securely | Required before the first real agent registers hours (Roadmap step 2). Pulse4all: Google Workspace through IAP |

Identity is matched on the external id in `app_user_external_id`, never on the email address, so a renamed address or the domain of someone's CRM seat does not matter.

**Pulse4all: Google Workspace through IAP** (decided 4 October 2026). Every Pulse4all user, Newco agents included, has a full pulse4all.com Google Workspace account. Two layers, one list:

- **Gate (IAP)** proves who the visitor is. During the build it admits only `cma@pulse4all.com`; at go-live it opens to `domain:pulse4all.com`
- **CMA (`app_user`)** decides who may work, with which role, employer and tenant. A pulse4all.com account without an active `app_user` row gets a "no access yet" page from the app and appears in Team as an access request. Nobody maintains a per-agent Google group
- The app verifies IAP's signed token (`x-goog-iap-jwt-assertion`) on every request and does not trust the plain identity headers. *Implemented 5 October 2026 in `web/src/proxy.ts` and `web/src/lib/auth/iap.ts`: ES256 against Google's IAP key set, issuer, audience, expiry and a future-issue check; the verified identity travels to the app in headers only the proxy can set, incoming copies are stripped; the token verifier (`web/verify/iap-token.mjs`) covers valid, missing, wrong audience, wrong issuer, expired, future issue, wrong signer and spoofed headers*
- The match key is the Google account's stable numeric id (IAP's `sub` claim is `accounts.google.com:<id>`; `iap.ts` strips the prefix and refuses any `sub` that is not that prefix plus digits), stored as system `google` in `app_user_external_id`; the email address is display only. The identity carries its provider (`google` behind IAP, `mock` in dev) in a third header only the proxy sets, `x-cma-identity-provider`, and the login looks up provider plus subject. In the app this is `findPrincipal(identity)` on the data interface (see API). In dev, where the web app runs behind Cloud Run IAM instead of IAP, the identity is a mock identity (provider `mock`) and the dev seed stores its subjects (`agent-one`, `agent-two`, `supervisor`, `manager`) under system `mock`, so a test subject can never match a real Google row. The subject is chosen per request: header `x-cma-mock-subject` (verifiers), or `?as=<subject>` once in the browser, which sets a cookie; an invalid subject is a 400, never a fallback. In iap mode the header, cookie and `?as=` are ignored. `agent-one` exists in two dev tenants on purpose and gets "no access yet" until a tenant picker exists
- People with a Google login are added per tenant with `db/09_seed_people_prod.sql`; each person reads their own id with `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" https://www.googleapis.com/oauth2/v3/userinfo` (the `sub` field). The ids are pasted into the Studio editor when running, never committed
- Suspending someone's Google account ends their access to the CMA at once; two-factor follows the Google Workspace policy
- This is Pulse4all's configuration. Another customer uses its own identity provider; the user list and external-id matching stay the same. Because a person may exist in two tenants, login includes a tenant lookup across tenants (`cma.find_tenants_for_identity`, a `SECURITY DEFINER` function owned by `cma_owner` that returns only tenant ids, migration 0002) and a tenant picker when more than one matches.

**CRM access for the desk.** Reading records live and writing diffs and engagements needs a HubSpot private app or OAuth app per tenant with read and write scopes on contacts, companies, deals, tickets and engagements; the token lives in Secret Manager and is used only by the adapter and the outbox worker, never by the browser.

A HubSpot app card (UI extension) can be added as a convenience shortcut. App cards appear on CRM records (contact, deal, ticket), not as a fixed main-menu item, and availability depends on the HubSpot subscription. The CMA itself is the home base, not a sub-page of HubSpot.

---

## Roadmap

Each step is delivered as increments; every increment goes to production once it is verified in dev (see Release flow). The order since 6 October 2026: finish the control layer, then Sync and the mirror, then configuration and roster, then messaging and speed to lead, then the queue engine and the agent desk for Subs, then the management and analytics views, then Invest. Rough effort for the engine, sync and the Subs desk together: 10 to 14 weeks of focused work after step 2.

1. **Foundation.** Google Cloud projects, Cloud SQL Postgres (EU), access and security, tenant and role model in the schema. *Done 4 October 2026: dev infrastructure (3 Oct), migration 0001 verified in dev, prod project created and 0001 verified there (4 Oct).*
2. **Workspace V1: workday, hours and the control layer.** The first screens at workspace.pulse4all.app: login, start and end the workday, own hours per day, week and month. Migration 0002 writes the time model fresh under the CMA conventions; the trial's agent UI source (`p4a-agent-ui-src.zip`: the My account panel, theme, building blocks, copy file) and its decisions are input. Desktop only (minimum 1280 px, keyboard-first), no offline mode. Needs no sync and no integrations. Login through Google Workspace and IAP (see Authentication). Before the first real agent uses it: the app's user check and IAP token verification, prod on dedicated core with high availability, heads-up to Yordi, then the gate opens from `cma@` to the pulse4all.com domain. *5 October 2026: `web/` scaffolded; My day (clock, end workday), My hours (today, week, month, custom range), No access yet and Log out live on mock data at workspace.pulse4all.app for the `cma@` group; IAP token verification real; Cloud Build pipeline and trigger; copy, theme, layout and token verifiers. Later on 5 October: migration 0002 (time model) run and verified in dev and prod; `db/` with all eight scripts in the repository. Evening of 5 October: the data layer on Postgres (`app_user` check, workday, hours) and the JSON API `/api/v1/me`, a private `cma-web` in dev, the API verifier (15 checks, provoked) against dev, prod switched to the database with Martin as the first person (manager); the screens now run on real data in prod. Remaining: Joshua and Finn in the people seed, the default status flags and the hours shown (Arno and Kira), heads-up to Yordi, prod high availability and `min-instances=1`, the baseline for business-case KPIs 1, 3, 5 and 7, then the gate opens.*
   Control-layer increments, from the demo analysis of 5 October (about 8 to 11 days together, no migration needed beyond one view and one function): (a) agent day at parity: status grid, timer, header chip, greeting and day line, pauses column and note chips on My hours; (b) a current-status view and the Live board; (c) Hours and export with the two CSVs, Correct a day and Add day on `correct_time_event`; (d) Dashboard on `workday_summary`.
3. **Sync and mirror.** Ingest API on Cloud Run with its service account as `cma_app` member and one key per tenant. HubSpot and Aircall adapters (Make scenarios, n8n on Cloud Run EU) mapping into the canonical entities through the ingest API; the customer-field mirror with the E.164 index (migration 0006); Aircall webhooks as the record of call facts; the outbox worker. BigQuery connection on `cma_read` with `bq_reader` (Joshua), BigQuery in the same region as Cloud SQL. Second heads-up to Yordi before the mirror lands in prod.
4. **Data first (in parallel).** The data prerequisites from the KPIs section in HubSpot and Aircall, plus Shopify orders into HubSpot, plus the Subs result-code catalog confirmed by Kira. First KPI reports for Kira can run from BigQuery as soon as sync and clean data are in place, before the CMA UI exists.
5. **CMA V1 for Pulse4all subscriptions, rest of the control layer.** Teams and skills (migration 0003) with the Team screen and access requests; configuration screens (statuses with flags, teams, skills and level scales, export formats); roster (migration 0004) with planner, agent schedule and the shift line; the scheduler for auto-closing forgotten days.
6. **Messaging and speed to lead.** Messaging (migration 0005): composer with targets, sent list with read and acknowledged counts, the Home list, the urgent pop-up, polling first and the realtime service when chosen; the ingest route for automations. Speed to lead (migration 0008): assignment, push via the outbox, accept click, accept window and expiry, the event log, the CRM adapter action for owner assignment.
7. **Queue engine.** Migration 0007 ported from the AgentUI trial's verified design under CMA conventions: campaigns, scoped result codes, tasks, leases, attempts, callbacks, counters and ceilings, `fn_serve_next`, `fn_book_disposition`, lease release and queue peek; the seven concurrency gaps the trial closed become verify blocks. Owner of tasks and dispositions written into Source of truth (done above).
8. **Agent desk for Subs.** The directive screen at parity with the Subs agent UI mockup: next task, record from the mirror with live refresh, field blocks, button grid with shortcuts, requirement-only dialogs, callback picker, memo, search outside the queue, incoming-call pop, Aircall embedded with one-click dial where possible, write-back through the outbox, who-saw-what audit. Heads-up to Yordi and the data processing view on customer data on the desk before real agents use it. Daily practice then shows whether Newco needs the desk or settles on HubSpot and Aircall; the assumption is that it does.
9. **Manager and analytics views.** Productivity (Total Calls Today first, then talk time per worked hour, Prepare and Finish time), benchmarking, effectiveness, coverage, gamification, live and quality monitoring, Kira's KPI dashboards and the first cohort reports (retention and payment behaviour per entry cohort from HubSpot, Shopify and NetSuite).
10. **Copy to Pulse4all Invest.** Configuration in the same database: `create_tenant`, organisations, channels, teams, skills, roles, the Invest campaign with its field blocks, result codes and the prospectus compliance hook for investor emails.
11. **First external customer.** New database, customer registry and migration runner, onboarding checklist derived from Data first, data processing agreement, and a second CRM or telephony adapter if that customer needs one.

Later modules follow the Target scope table.

**Convergence: the version where everything comes together.** After step 11 the remaining sources are connected one adapter at a time, each as an increment that adds its activity events and its cohort attributes to the same model: the shared Gmail mailbox, SMS and chat, the Customer App (as a channel and as a self-service source), NetSuite (payments and dunning), Shopify and Juo directly where HubSpot's copy is not enough, and the Asset Management Database (devices and service). The version in which all of them feed the Workspace is the convergence version; its number is set when that part of the roadmap is cut. From then on the Workspace is the one point where the agent's next task, the team's day and every management layer's reporting come from one database.

---

## Out of scope

- **Replacing the CRM.** Contacts, deals and tickets live in the CRM; the CMA mirrors what it needs and writes outcomes back. The CMA never becomes the customer record.
- **Telephony itself.** IVR, inbound routing, recording and the phone app stay with Aircall; the CMA embeds the softphone and consumes events.
- **Callpit and the Subs agent UI as code.** The AgentUI trial's cockpits (`callpit.netlify.app`, `p4a-agent-ui-subs-dev.netlify.app`) are input: their queue-engine design, result-code registry, Aircall findings, screens, copy and decisions are ported under the CMA conventions in Roadmap steps 7 and 8; their code is not carried over as-is (decided 6 October 2026).
- **The Neon/Netlify trial** (Workspace, agent UI, queue engine; see the AgentUI handover of 4 October 2026). It was concepting and testing, not production. Its UI source and decisions are input for the CMA; its code is not carried over as-is. The trial's Workspace schema and validated hours export are not available, so the hours export is rebuilt and re-validated against an anonymised copy of the Steam hours CSV. The demo at `contactcenter.pulse4all.app` (Firebase) is the UI and interaction blueprint for the management screens and the agent's day; its data layer is not adopted.
- **Customer data on the management screens.** Live, Report and Data show no customer data; alerts carry case status and a link. The agent desk shows the record it serves (see Architecture, Customer data).
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
| 3 Oct 2026 | Working title renamed to Contactcenter-Management-App; the abbreviation CMA and everything carrying it (project IDs, group, roles, secrets) stay | Channels are configuration and nothing assumes phone; "call center" in the title contradicted that. Still a working title: the product name is decided at Roadmap step 11 with Mark |
| 4 Oct 2026 | Customer configuration (tenants, organisations, channels) and dev test data live in separate seed scripts, not in the migration | The same migration runs unchanged in dev, prod and every customer database; test data can never reach prod by accident |
| 4 Oct 2026 | Prod starts on the same shared-core machine as dev; dedicated core with high availability before real data lands | Nothing to keep available while the database is empty; saves about €80 a month until real data flows; the switch is an instance edit with a short restart |
| 4 Oct 2026 | Every migration, seed and verify script runs under a personal IAM login; a guard refuses `postgres` unless `cma.emergency` is set | The 0001 seed in prod was applied via `postgres` under `cma_owner`; those audit rows stay as recorded (`actor_login = postgres`), the audit trail must name a person from now on, and the emergency path remains available on purpose |
| 4 Oct 2026 | The Neon/Netlify Workspace and agent UI were a trial; the permanent setup is the CMA on Cloud SQL and Cloud Run at workspace.pulse4all.app. Trial schema, designs and tests are ported under the CMA conventions, not copied | One foundation with tenants, RLS, audit and EU hosting; the trial proved the concepts |
| 4 Oct 2026 | Workday and hours (Roadmap step 2) come before Sync; Authentication V2, prod high availability and the heads-up to Yordi move forward with it | Hours need no integrations, and a working screen early beats weeks of backend without anything to use |
| 4 Oct 2026 | workspace.pulse4all.app runs through a global external Application Load Balancer with IAP in front of Cloud Run; DNS stays at IONOS with one A record | Cloud Run domain mapping is preview and not recommended for production; IAP keeps the site closed to anyone outside the team during the build |
| 4 Oct 2026 | Authentication V2 for Pulse4all is Google Workspace through IAP; the CMA's `app_user` is the single list of who may work; identity matched on the Google account id | Every user, Newco agents included, has a full pulse4all.com account: no extra login system or licence cost, offboarding follows the Google account. The V1 HubSpot-id screen is not built |
| 4 Oct 2026 | Code in the private GitHub repository `Pulse4all-com/cma`, owned by a Pulse4all organisation; builds in Cloud Build | Ownership independent of personal accounts; a later move to an EU-hosted Git service stays cheap. EU sovereignty of the code is revisited at Roadmap step 11 together with the rest of the stack |
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
| 6 Oct 2026 | The demo at `contactcenter.pulse4all.app` is the UI and interaction blueprint for the management screens and the agent's day: its screens, flows, copy and behaviour rules are adopted (about 99 percent), its Firebase data layer is not | The screens and copy are right and in the house style; the data layer trusts the device clock, has no tenant, audit or server-side rules, and migration 0002 already covers that half better. Analysis of 5 October 2026 in the project artifacts |
| 6 Oct 2026 | Callpit and the Subs agent UI contribute patterns, the My account panel, the Aircall findings and the queue-engine design; their code is not carried over | Both run on mock data with a public Make webhook; the engine design is verified and the screens are the shortlist for the agent desk. Analyses of 5 October 2026 in the project artifacts |
| 6 Oct 2026 | The CMA becomes a directive contact-center suite: an agent desk that serves the next task (Steam Connect-like) plus the management layer, on one foundation. HubSpot stays the CRM; Postgres owns the work queue; the agent never waits on an integration | Agent productivity dropped moving from Steam to HubSpot with the Aircall plugin: picking tasks from lists and clicking through records is not built for working fast at scale. Daily practice will show whether Newco needs the desk; the assumption is that it will |
| 6 Oct 2026 | Universal by default is a development rule: every feature is built for a roll-out to other organisations even if that roll-out never happens; Pulse4all is tenant 1 and seed data; vendor specifics sit behind adapter interfaces | Every organisation on a CRM plus a phone plugin faces the same gap; the layer the CMA offers is workforce, productivity and management on top of CRM plus phone |
| 6 Oct 2026 | Teams and skills: 0 teams (membership, markets: Team EN, NL, DE, FR, Nordics), 1 languages with the four-step scale Basic, Good, Fluent, Native, 2 work types (Sales, Operations, Debt, …); channel kept as an empty dimension; eligibility derived at serve time | One model serves the queue's hard filters, the roster's coverage, message targeting and the My account panel; team and language must be separate for Nordics |
| 6 Oct 2026 | Postgres on Cloud SQL stays the operational core; the CRM is never squeezed. Customer facts are owned by the CRM, Postgres holds a mirror of the fields the Workspace needs (filled by the sync, updated from the CRM's answer, following CRM deletions), work facts live only in Postgres. Setup: front = Workspace; backend = PostgreSQL, CRM, Aircall, Make, n8n, Cloud Run EU | The desk must serve the next task and show the record instantly whether or not the CRM is fast or up; the CRM keeps the customer record; data minimisation bounds the mirror to declared fields |
| 6 Oct 2026 | n8n joins Make as an automation runtime, on Cloud Run EU; both reach the CMA only through the ingest API and the outbox webhooks | Same reasoning as the 3 October ingest decision; n8n next to the CMA keeps that automation in the same region and project |
| 6 Oct 2026 | Write-back to the CRM is limited to field diffs, engagements with the result code, do-not-call, owner assignment and optionally callbacks as CRM tasks (tenant setting); everything else stays in Postgres | Customer facts to the CRM, work facts in Postgres; CRM-only colleagues stay informed where it matters |
| 6 Oct 2026 | Statuses within the workday cover pauses, training, meetings and work on other projects or business lines from V1, with an optional activity code per status; a status change also sets the agent's telephony availability through the adapter, mapping per status as tenant configuration | One clock, one action: the phone follows the status, time on other projects is reportable without a second system; the set-availability call is verified before it is marked done |
| 6 Oct 2026 | Reporting for every management layer from the combined sources plus staff is the product's reporting proposition: every outcome attributed to an agent and a time interval through the canonical activity event; productivity per agent per worked hour and benchmarking are first-class | The join of channel events with clock, statuses, teams and employer is what no CRM, telephony tool or shop platform can make; the buy-in for Kira and for Peter on Invest |
| 6 Oct 2026 | Cohorts are a first-class reporting concept: customers by entry month, country, source, proposition and converting agent or team, followed over time for retention, payment behaviour, reviews, service and value; agents as cohorts too | Period reports hide whether a cohort stays and pays; cohort definitions are tenant configuration in the metric catalog, confirmed by Kira and Peter |
| 6 Oct 2026 | The Customer App is a channel (a `channel` row and a source of activity events); the Asset Management Database is a data source for cohort attributes and agent work; both are connected after step 11 as part of the convergence version | Channels are configuration; the model carries every source from the start and fills them one adapter at a time |
| 6 Oct 2026 | The business case is written into the README as ten KPIs with baseline, target and ROI line, reviewed quarterly; baselines are taken before each increment reaches agents; the external roll-out is never counted | A business case without a baseline cannot be proven or disproven; the targets are changed in the table when they turn out wrong, not argued over later |
| 6 Oct 2026 | One CMA for all Pulse4all entities (Subs, Invest, later US), each with its own HubSpot portal and Aircall account: one adapter instance per tenant with its own credentials and mappings; aggregation across tenants at the customer level in `cma_read` and BigQuery; CRM-agnostic is therefore a V1 fact, not a future option | No portal can see another portal, so the operation comes together only outside them; three portals already behave like three CRMs and need exactly the per-tenant adapter a second CRM type needs |
| 6 Oct 2026 | AI agents working the queue are expected; `app_user` gets a worker kind when the first one does, and the queue, attribution, reporting and compliance trail apply to people and AI agents alike. HubSpot and Aircall are not treated as the main competitors | The screens will change, the layer of record for work will not; the cross-vendor join is outside both vendors' focus |

---

## Open decisions

- Per customer: a separate Cloud SQL instance or project, or a separate database on a shared instance (IAM users and the superuser are instance-level, so instance or project per customer is the stronger boundary); decide at the first external customer.
- Timing of the heads-up to Yordi and of prod high availability: both were set before real data lands, and since 5 October prod holds the team's own working time. Proposal: send the heads-up now; keep shared core for team-only use and switch to dedicated core with high availability before the first agent hours. A second heads-up, plus the processor view and who-saw-what audit, before the mirror (step 3) and the desk (step 8).
- Tenant picker: needed before anyone works for two tenants (in dev `agent-one` shows the refusal); a screen after login, or a default tenant per person; plus the "all business lines" reporting view for customer-level readers in the Workspace.
- Pulse4all US as the third tenant: region and residency (EU-only folder policy versus a US region, which would mean its own customer database and project), currency, time zones and languages in configuration; decide when US is set up.
- Matching the same customer across the Subs, Invest and US portals for cohort reporting: purpose limitation and legal basis across business lines, with Yordi, before it is built.
- Aircall accounts per tenant: one webhook endpoint per account with its own secret on the ingest API; per-number settings checklist per account.
- Roles in prod: the team has `manager` while building. Proposal from the demo (6 October): an `admin` role on the ladder for configuration, user management and connections, operations for managers; confirm with Arno and Kira before agents join.
- `min-instances=1` on `cma-web` before agents use it (a few euros a month); keep at 0 while only the team tests.
- Hours registration and employment status: Wet DBA if Newco agents are freelancers, and Spain's daily working-time registration duty (whether the CMA becomes that record, retention); with Yordi and Arno before real use.
- Copy language of the Workspace for multilingual Newco agents: English and Dutch exist in `web/src/lib/copy.ts`, default English via `CMA_DEFAULT_LOCALE`; per-campaign copy and theme become tenant configuration (from the Subs agent UI); whether locale becomes a per-user setting (with Kira).
- Forgotten clock-outs: migration 0002 leaves the day open, flags it and caps its hours at the end of the business day; a manager closes it with a correction. Still open: the scheduler's rule once Sync runs (roster end time, last Aircall or HubSpot activity, or the trial's rule: a tenant-configured hour using the last disposition), and whether the agent may propose an end time from a dialog, stored as a correction awaiting a supervisor's approval (the demo lets the agent enter it, flagged).
- Default status flags (paid break, billable training and meetings, unpaid lunch), Pulse4all's own status list as seed (the demo's fifteen minus End of Shift), the derived colour rule, and which hours the agent's screen shows (working, as built, paid, or the demo's total with "of which pauses"): confirm with Arno and Kira before real hours; a change is an update on `work_status`, not a migration.
- Export format (separator, decimal mark, date format) as tenant settings, Pulse4all seeded to Dutch Excel conventions (semicolon, decimal comma, `dd-mm-yyyy`).
- Roster cells: structured start and end plus absence types, with the demo's quick-typing parser as the entry method; confirm with Arno.
- Urgent messages: read and acknowledged as two facts, the urgent pop-up writes acknowledged; quiet hours.
- Total Calls Today and other productivity figures: whether agents see colleagues' numbers (gamification), with Arno.
- One-click dial through `POST /v1/users/:id/calls`: verify against a live Aircall account that it works with the embedded Workspace rather than only the desktop Phone app, and the plan coverage; otherwise `dial_number` stays two clicks.
- Setting an agent's Aircall availability per user through the API (the status-to-availability mapping of Features 1): endpoint, plan coverage and the custom statuses Aircall allows (Out for lunch, On a break, In training, Back office, Other); if not possible, mismatch display only.
- Cohort definitions for Pulse4all (entry, country, source, proposition, converting agent or team) and the payment-behaviour measures (days to pay, dunning stages, collections) with Kira and Peter; which system holds the Asset Management Database and how it is reached; the Customer App's event feed (webhooks or API) and how its interactions are attributed to an agent when one is involved.
- Benchmarking agents across employers and countries: what agents see of each other, what the partner's HR sees, retention of per-agent performance history (employee-monitoring rules in NL and Spain, with Yordi).
- HubSpot API rate limits for the desk's write-back and live reads at Newco's volume; private app versus OAuth app per tenant; search-by-phone limits make the mirror's phone index necessary.
- Result-code seeds for Subs (semantics, priorities, retry intervals, do-not-call flags) with Kira; do-not-call scope across business lines (one boolean on the contact today) with Peter and Kira.
- Callback appointments written back to the CRM as tasks: tenant setting, default on or off.
- Dev identities as system `mock` with a subject switch per request for two-user tests: decided for dev; to revisit if Cloud Run's direct IAP integration lets dev run with real Google identities without a load balancer (check when the first real agent is in dev).
- Parallel run against the Steam Connect hours export before Steam is switched off for hours.
- Product and legal setup for offering the CMA to other companies: Pulse4all product or separate entity, naming, where the Google Cloud folder lives, processor role and data processing agreement per customer (with Yordi and Mark).
- Competitive check against workforce-management tools that integrate with Aircall (Assembled, Playvox, injixo, Surfboard) and against agent desks on CRM plus telephony before the external pitch; HubSpot and Aircall themselves are not expected to be the main competitors (their focus is CRM and telephony, not an operating system for the team).
- Business case: confirm the ten targets with Arno, Kira and Peter; the hourly rate per employer and the margin per order for the ROI line come from finance and stay out of the README; who takes and records the baselines, and when the first quarterly review is.
- Assignment tie-breaker when several agents are available (longest idle, fewest leads today, round robin?).
- What happens when no matching agent is available (queue, fallback skill, notify manager?); the queue engine's "campaign has queued work and no eligible agent" check at campaign creation.
- Whether an agent who lets a lead expire is automatically set to an "away" status.
- Can one person work for two business lines on the same day, and if so where does the time clock live (today: one user and one clock per tenant).
- Default role ladder and permissions: confirm the seed with Arno and Kira.
- Owner of customer contact details: Shopify or customer portal.
- Shared mailbox: agreement that customer mail goes through HubSpot, which depends on making attachments as easy in HubSpot as in Gmail. Also how to attribute replies to individual agents.
- Choice of realtime push service: managed (Pusher Channels, Ably; check EU data residency and pricing) vs self-hosted (Centrifugo on Cloud Run) vs custom WebSocket service. Decide in Roadmap step 6; polling is the fallback.
- Scheduler: Cloud Scheduler with a Cloud Run job, or pg_cron on Cloud SQL (check availability for PostgreSQL 18).
- HubSpot subscription check for UI extensions and OAuth.
- NetSuite connectivity (Make module vs. direct API).
- Plan B for agents if the CMA is down (today: HubSpot and Aircall as they work now).
- Source of review data per country and how it links to deals.
- Office hours per country, used for speed-to-lead and SLA calculations.
- Handling of UK vulnerability data in Postgres, in CMA alerts and on the desk's GB records (with Yordi).
- Retention of staff data, the audit log and the customer-field mirror; employee monitoring rules in NL and Spain; quiet hours for notifications (with Yordi).
- Cloud SQL's Knowledge Catalog integration (on by default on both instances, shares schema metadata only, not data): keep or switch off (with Yordi).
- Which Aircall AI features (transcripts, sentiment, playbooks) are in the current Aircall plan.
- Tool for the short satisfaction question after a call or ticket.

*Last updated 6 October 2026 (fourth pass): one CMA across Subs, Invest and later US, each with its own HubSpot portal and Aircall account, one adapter instance per tenant, aggregation at the customer level; CRM-agnostic as a V1 fact; reason 8 under Why standalone; US region and cross-portal matching as open decisions. Third pass, same day: the plain-words description and the assessment of feasibility, value, AI and competition; the business case as ten KPIs with baseline, target and ROI line; baseline-taking added to step 2; worker kind for AI agents on `app_user`. Second pass, same day: statuses for pauses, training and other projects within one clock with telephony availability following the status; reporting for every management layer from the combined sources plus staff as the product's proposition, with the canonical activity event as the join; cohorts as a first-class reporting concept (KPIs section 12); the Customer App as a channel and the Asset Management Database as a source; the convergence version after step 11. Earlier the same day: the direction. The CMA becomes a directive contact-center suite with an agent desk beside the management layer; universal by default as a development rule; teams, languages with four levels and work types as the people model; Postgres on Cloud SQL as the operational core with a bounded mirror of customer fields; n8n beside Make through the ingest API and outbox; the demo at contactcenter.pulse4all.app as UI blueprint, Callpit and the Subs agent UI as input for the desk; planned migrations 0003 to 0008; the roadmap resequenced (control layer, sync and mirror, configuration and roster, messaging and speed to lead, queue engine, desk for Subs, views, Invest, first external customer). Earlier, 5 October (late evening): the API on Postgres in-process, JSON API `/api/v1/me`, prod on the database with Martin as the first person.*
