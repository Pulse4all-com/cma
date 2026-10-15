# NocoDB: a read-only table browser over cma_read

Purpose: give the team a spreadsheet-like way to look at the reporting views in `cma_read` without
writing SQL. NocoDB is self-hosted on Cloud Run (service `cma-nocodb`, europe-west4), one per
project. It reads `cma_read` through the IAM database user of its own service account, via a Cloud SQL
Auth Proxy sidecar, and keeps its own metadata in a separate database `nocodb` on the same instance.
It sits behind IAP for `cma@pulse4all.com`. NocoDB Cloud is not used (README, Decision log, 9 Oct 2026).

Files here: `service.template.yaml` (the Cloud Run service), `deploy.sh` (renders and deploys it),
`grants.sql` (template, never committed filled in).

## Status

| Environment | Done | Still to do |
|---|---|---|
| dev (`p4a-cma-dev`) | complete on 9 Oct 2026: steps 1 to 9 (service account and roles, IAM user, database `nocodb`, grants with a passing verdict, both secrets, deploy, IAP, first admin martin@pulse4all.com, `cma_read` connected read-only) | nothing |
| prod (`p4a-cma-prod`) | complete on 9 Oct 2026: revision `cma-nocodb-00001`, IAP on, first admin martin@pulse4all.com, data source `cma_read` connected read-only | nothing. NocoDB shows agent hours, which are personal data: decide which `cma_read` columns the team may see before handing out workspace roles |

Since 15 Oct 2026 `service.template.yaml` caps NocoDB's two connection pools at 3 each (Database connections, below). Until "Applying the pool caps" has run in an environment, its running revision still has the old pools.

## Pinned versions

| Image | Version | Date | Digest |
|---|---|---|---|
| `docker.io/nocodb/nocodb` | 2026.09.0 | published 2026-09-10 | `sha256:4ccfc5114506b1725ffc63be56445fc6fe453a6e6d5cb56eb5f88f0540d4e56e` |
| `gcr.io/cloud-sql-connectors/cloud-sql-proxy` | 2.25.4 | built 2026-08-28 | `sha256:88501f0a695a586988add1b8a206fdf3f29f9a1a3deeb9b45ef2b1481ea6be83` |

Rule: the newest release that is at least 14 days old, pinned by tag and digest. Newer at the time of
pinning (9 Oct 2026) and skipped: NocoDB 2026.09.1 (29 Sep), proxy 2.26.0 (28 Sep).

## Database connections

NocoDB opens two connection pools on the instance, both through the proxy sidecar as `cma-nocodb@PROJECT.iam`. Both are capped at 3, so NocoDB holds at most 6 connections (README, Infrastructure, Database connection budget). The settings were checked against the source of the pinned NocoDB 2026.09.0 and its knex 3.1.0. Check them again whenever the image is bumped.

| Pool | Database | Setting in `service.template.yaml` | How NocoDB 2026.09.0 reads it | Without it |
|---|---|---|---|---|
| NocoDB's metadata | `nocodb` | `"pool":{"min":0,"max":3}` inside `NC_DB_JSON` | `NC_DB_JSON` is parsed and passed to knex unchanged (`packages/nocodb/src/utils/nc-config/NcConfig.ts`, `src/meta/meta.service.ts`) | knex's default, min 2 and max 10, so 2 stay open while NocoDB runs |
| Every external source, here `cma_read` | `cma` | `NC_DB_POOL_MAX: "3"` | Each source's pool is `{ min: 0, max: NC_DB_POOL_MAX }` (`src/utils/nc-config/constants.ts`), with the source's own settings spread over it (`src/utils/common/NcConnectionMgrv2.ts`) | max 10 |

- **No `pool` in a source's own settings.** The connection form of setup step 9 stores no pool, so `NC_DB_POOL_MAX` applies. Never put a `pool` key in a connection's Advanced options JSON: it would replace the cap for that source.
- **One pool per source.** A second external source gets a pool of its own, 3 more connections, and updates the budget first.
- **Short-lived extras.** NocoDB briefly opens one more connection at startup, to check that its metadata database exists, and for "Test connection" on the Integrations page. Each closes again within seconds.
- **Idle connections close.** With `min` 0 an idle connection closes after 30 seconds (the default of tarn, knex's pool), and the service scales to 0 when nobody uses it.

## Applying the pool caps (15 October 2026)

After this change is merged, dev first, then prod. Each deploy creates a new revision, which restarts NocoDB with the new settings. Nothing else changes.

1. **Terminal:** check the rendered settings.
   ```bash
   cd ~/cma && git switch -q main && git pull -q --ff-only && docs/nocodb/deploy.sh dev --dry-run | grep -E "NC_DB_JSON|NC_DB_POOL_MAX" -A1
   ```
   Expected: the `NC_DB_JSON` value ends with `"database":"nocodb"},"pool":{"min":0,"max":3}}'`. `NC_DB_POOL_MAX` is followed by `value: "3"`.
2. **Terminal:** deploy to dev.
   ```bash
   cd ~/cma && docs/nocodb/deploy.sh dev
   ```
   Expected: the service URL, then the latest ready revision, a newer one than before the deploy.
3. **Browser:** the dev service URL. Open the base "CMA dev (read-only)" and click through three or four tables and views of `cma_read`.
   Expected: the rows appear as before.
4. **Studio (cma-dev-pg)**, right after step 3:
   ```sql
   select usename, datname, count(*) as connections
   from pg_stat_activity
   where usename like 'cma-nocodb%'
   group by 1, 2 order by 2;
   ```
   Expected: at most two rows, `cma` with at most 3 and `nocodb` with at most 3. NocoDB holds at most 6 in all. Both counts may already be lower, or the rows gone, once NocoDB has been idle for half a minute.
5. Steps 1 to 4 for **prod**: `deploy.sh prod`, the base "CMA prod (read-only)", Studio on **cma-prod-pg**.
   Expected: the same, `cma-nocodb@p4a-cma-prod.iam` at most 3 on `cma` and at most 3 on `nocodb`.
6. **Studio (cma-prod-pg):** every login, for the budget.
   ```sql
   select coalesce(usename, '(background)') as login, coalesce(datname, '') as database, count(*) as connections
   from pg_stat_activity group by 1, 2 order by 3 desc;
   ```
   Expected: `cma-nocodb@p4a-cma-prod.iam` at most 6 over its two rows, `cloudsqladmin` a few (4 on 15 October 2026), `(background)` the server's own processes, your own login, and `cma-web@…` and `cma-ingest@…` only while they are busy. Save the output as `records/nocodb-pools-prod-<date>/studio.txt` with step 4's output for dev and prod: values from your runs only.

If a count is higher than 3 on one database, the revision did not take the settings. Run step 1 again and check that `gcloud run services describe cma-nocodb --region=europe-west4 --project=PROJECT --format=export | grep -A1 NC_DB_POOL_MAX` shows the value 3, then send me the output.

## Setup order

Every command below runs in **Terminal** (Cloud Shell) unless it says Studio. Replace `ENV` with `dev` or `prod`,
`PROJECT` with `p4a-cma-dev` or `p4a-cma-prod`, `INSTANCE` with `cma-dev-pg` or `cma-prod-pg`.

1. **Service account and roles.**
   ```bash
   gcloud iam service-accounts create cma-nocodb --project=PROJECT --display-name="CMA NocoDB"
   for r in roles/cloudsql.client roles/cloudsql.instanceUser; do
     gcloud projects add-iam-policy-binding PROJECT --member="serviceAccount:cma-nocodb@PROJECT.iam.gserviceaccount.com" --role="$r" --condition=None
   done
   gcloud projects get-iam-policy PROJECT --flatten="bindings[].members" --filter="bindings.members:serviceAccount:cma-nocodb@PROJECT.iam.gserviceaccount.com" --format="value(bindings.role)"
   ```
   Always run the `get-iam-policy` check after the two bindings. Expected: both `roles/cloudsql.client` and `roles/cloudsql.instanceUser`. On prod, `roles/cloudsql.client` was missing after the first run (two project policy changes in quick succession) and had to be added again; run the missing binding again.
2. **IAM database user.**
   ```bash
   gcloud sql users create cma-nocodb@PROJECT.iam --instance=INSTANCE --project=PROJECT --type=cloud_iam_service_account
   ```
3. **Database `nocodb`.**
   ```bash
   gcloud sql databases create nocodb --instance=INSTANCE --project=PROJECT
   ```
4. **Grants.** In **Studio** on INSTANCE, as `postgres`, connected to database `nocodb`: paste `docs/nocodb/grants.sql`
   with `__PROJECT__` replaced, run it, and check the verdict: `nocodb_create`, `public_create`, `cma_connect`,
   `reads_cma_read` true; `is_owner`, `is_app` false. Do not save the filled copy.
5. **Secrets** (64 hex characters each, readable by the service account only).
   ```bash
   for s in jwt-secret encrypt-key; do
     openssl rand -hex 32 | tr -d '\n' | gcloud secrets create cma-ENV-nocodb-$s --project=PROJECT --replication-policy=user-managed --locations=europe-west4 --data-file=-
     gcloud secrets add-iam-policy-binding cma-ENV-nocodb-$s --project=PROJECT --member="serviceAccount:cma-nocodb@PROJECT.iam.gserviceaccount.com" --role=roles/secretmanager.secretAccessor
   done
   ```
6. **Deploy.** Check first, then deploy.
   ```bash
   cd ~/cma && docs/nocodb/deploy.sh ENV --dry-run | less
   cd ~/cma && docs/nocodb/deploy.sh ENV
   ```
   It prints the service URL and the latest ready revision. The service has no public invoker; do not open it up.
7. **IAP on the service** (Cloud Run's built-in IAP, no load balancer), for the group `cma@pulse4all.com`.
   Verified on dev on 9 Oct 2026. `PROJECT_NUMBER` is 420011670185 for dev and 467777891162 for prod.
   On a new service, before `deploy.sh`, create the IAP service agent (beta command; it needs the IAP API enabled, so run the first line of the block below first if it fails):
   ```bash
   gcloud beta services identity create --service=iap.googleapis.com --project=PROJECT
   ```
   Then:
   ```bash
   gcloud services enable iap.googleapis.com --project=PROJECT
   gcloud run services update cma-nocodb --region=europe-west4 --project=PROJECT --iap
   gcloud run services add-iam-policy-binding cma-nocodb --region=europe-west4 --project=PROJECT --member=serviceAccount:service-PROJECT_NUMBER@gcp-sa-iap.iam.gserviceaccount.com --role=roles/run.invoker
   gcloud iap web add-iam-policy-binding --project=PROJECT --region=europe-west4 --resource-type=cloud-run --service=cma-nocodb --member=group:cma@pulse4all.com --role=roles/iap.httpsResourceAccessor
   ```
   Notes:
   - The IAP service agent must exist before the binding to `service-PROJECT_NUMBER@gcp-sa-iap.iam.gserviceaccount.com` works: run `gcloud beta services identity create` (above) on a new service. Dev got it implicitly from `services update --iap`; prod needed it explicitly.
   - If the browser shows "You don't have access" while both IAP bindings exist, wait a few minutes or use an incognito window: IAP can keep an earlier denial in a cookie.
   - `service.template.yaml` carries `run.googleapis.com/iap-enabled: 'true'` on the service, so a redeploy with `deploy.sh` keeps IAP on. For prod, enable the IAP API (the first command) before the first `deploy.sh prod`.

   Checks, each in **Terminal**:
   ```bash
   gcloud run services describe cma-nocodb --region=europe-west4 --project=PROJECT --format=export | grep iap
   gcloud iap web get-iam-policy --project=PROJECT --region=europe-west4 --resource-type=cloud-run --service=cma-nocodb
   gcloud run services get-iam-policy cma-nocodb --region=europe-west4 --project=PROJECT
   curl -s -o /dev/null -w '%{http_code}\n' SERVICE_URL
   ```
   Expected, in that order: `run.googleapis.com/iap-enabled: 'true'`; only `roles/iap.httpsResourceAccessor` for `group:cma@pulse4all.com`; only `roles/run.invoker` for the IAP service agent (no `allUsers`); `302`.
   Then check in the **Browser**: the service URL asks for a Google login, and a person outside the group is refused.
8. **First NocoDB admin and signup.** The first account to sign up becomes the super admin. In the **Browser**, open
   the service URL and create it before anyone else can. In NocoDB 2026.09.0 self-signup still works despite
   `NC_INVITE_ONLY_SIGNUP: "true"` in `service.template.yaml` (tested on 9 Oct 2026; the variable is kept in case a later
   version honours it). A test account created that day landed with workspace role "No Access" (no bases, no data)
   and was removed. Access control is IAP (only the group `cma@pulse4all.com` reaches NocoDB) plus the workspace
   roles the owner hands out; new accounts get No Access by default. After each self-signup, check Invite Members
   and remove unknown accounts.
   - dev: martin@pulse4all.com signed up on 9 Oct 2026.
   - prod: martin@pulse4all.com signed up on 9 Oct 2026. For any new service, sign up the first admin immediately after the first deploy.
9. **Connect database `cma`, schema `cma_read` only** (verified on dev, 9 Oct 2026). In **Browser**:
   - Integrations → PostgreSQL connection "cma-ENV (cma_read)": host `127.0.0.1`, port `5432`, user
     `cma-nocodb@PROJECT.iam`, password any value such as `iam` (ignored, the proxy logs in with IAM), database `cma`,
     schema `cma_read`, SSL off (the proxy encrypts to Cloud SQL).
   - Base "CMA ENV (read-only)" → Connect External Data → source `cma_read` on that connection, Allow Data Write/Edit
     off, Allow Schema Change off.
   - Do not use Import Data or Sync data: they copy data into NocoDB.
   - Give team members a read-only workspace role, never Creator or Editor.

## Notes

- Autoscaling is 0 to 1, so the first request after idle waits for a cold start (the startup probe allows up to five minutes).
- The proxy signs in with `--auto-iam-authn`, so no database password exists anywhere; NocoDB's own `NC_DB_JSON` has an empty password on purpose; the password in the connection form of step 9 is a placeholder.
- The two secrets are the only secrets; never paste their values into a command, a commit or a PR.
- The UI of NocoDB shows data from `cma_read`; the rule that the CMA's own UI shows no customer data applies to the CMA's screens, so decide before connecting a prod source which `cma_read` columns the team may see.
