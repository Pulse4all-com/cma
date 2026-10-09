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
| dev (`p4a-cma-dev`) | steps 1 to 5 by hand on 9 Oct 2026 (service account and roles, IAM user, database `nocodb`, grants with a passing verdict, both secrets); deployed (revision `cma-nocodb-00001`) and IAP on, 9 Oct 2026 | steps 8 and 9: first admin, connect `cma_read` |
| prod (`p4a-cma-prod`) | nothing yet | all steps, with the same files |

## Pinned versions

| Image | Version | Date | Digest |
|---|---|---|---|
| `docker.io/nocodb/nocodb` | 2026.09.0 | published 2026-09-10 | `sha256:4ccfc5114506b1725ffc63be56445fc6fe453a6e6d5cb56eb5f88f0540d4e56e` |
| `gcr.io/cloud-sql-connectors/cloud-sql-proxy` | 2.25.4 | built 2026-08-28 | `sha256:88501f0a695a586988add1b8a206fdf3f29f9a1a3deeb9b45ef2b1481ea6be83` |

Rule: the newest release that is at least 14 days old, pinned by tag and digest. Newer at the time of
pinning (9 Oct 2026) and skipped: NocoDB 2026.09.1 (29 Sep), proxy 2.26.0 (28 Sep).

## Setup order

Every command below runs in **Terminal** (Cloud Shell) unless it says Studio. Replace `ENV` with `dev` or `prod`,
`PROJECT` with `p4a-cma-dev` or `p4a-cma-prod`, `INSTANCE` with `cma-dev-pg` or `cma-prod-pg`.

1. **Service account and roles.**
   ```bash
   gcloud iam service-accounts create cma-nocodb --project=PROJECT --display-name="CMA NocoDB"
   for r in roles/cloudsql.client roles/cloudsql.instanceUser; do
     gcloud projects add-iam-policy-binding PROJECT --member="serviceAccount:cma-nocodb@PROJECT.iam.gserviceaccount.com" --role="$r" --condition=None
   done
   ```
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
   ```bash
   gcloud services enable iap.googleapis.com --project=PROJECT
   gcloud run services update cma-nocodb --region=europe-west4 --project=PROJECT --iap
   gcloud run services add-iam-policy-binding cma-nocodb --region=europe-west4 --project=PROJECT --member=serviceAccount:service-PROJECT_NUMBER@gcp-sa-iap.iam.gserviceaccount.com --role=roles/run.invoker
   gcloud iap web add-iam-policy-binding --project=PROJECT --region=europe-west4 --resource-type=cloud-run --service=cma-nocodb --member=group:cma@pulse4all.com --role=roles/iap.httpsResourceAccessor
   ```
   Notes:
   - `services update --iap` creates the IAP service agent itself. `gcloud services identity create` is beta-only in the current gcloud and not needed.
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
8. **First NocoDB admin, signup off.** In the **Browser**, open the service URL and create the first account (it becomes
   the super admin). Then, in the account's settings, turn invite-only signup on so nobody else can register themselves.
9. **Connect database `cma`, schema `cma_read` only.** In NocoDB add an external data source (PostgreSQL):
   host `127.0.0.1`, port `5432`, user `cma-nocodb@PROJECT.iam`, empty password, database `cma`. In the source's
   schema selection pick `cma_read` and nothing else. Give team members the Viewer role, never Creator or Editor.

## Notes

- Autoscaling is 0 to 1, so the first request after idle waits for a cold start (the startup probe allows up to five minutes).
- The proxy signs in with `--auto-iam-authn`, so no database password exists anywhere; NocoDB's own `NC_DB_JSON` has an empty password on purpose.
- The two secrets are the only secrets; never paste their values into a command, a commit or a PR.
- The UI of NocoDB shows data from `cma_read`; the rule that the CMA's own UI shows no customer data applies to the CMA's screens, so decide before connecting a prod source which `cma_read` columns the team may see.
