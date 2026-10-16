# cma-ingest in prod without its front, 16 October 2026

An incident on the prod ingest service `cma-ingest` in p4a-cma-prod, and its fix by hand in the
Console. Written down by Claude Code at Martin's request from his report; the revisions, the image
tag and the times below are his. Times are CEST as he reported them (UTC + 2 h on that date). No
secret, no connection key and no customer data appears here.

## What happened

- Revision `cma-ingest-00008` (image `1146ee3`) was deployed with `bash docs/ingest/deploy.sh prod`,
  without `--front`. The time of that deploy is not in the report.
- Without `--front`, `deploy.sh` set the ingress to `all`, so the `run.app` address was open to the
  internet, and `INGEST_PUBLIC_URLS` to the service's two `run.app` addresses only, without
  `https://ingest.pulse4all.app`.
- HubSpot signs the URI it calls, `https://ingest.pulse4all.app/hubspot/<connection key>`, and the
  service checks the signature against the addresses in `INGEST_PUBLIC_URLS` only. From that deploy
  until 08:15 CEST every HubSpot webhook signature failed: 401 `authentication failed`.

## The fix in the Console

Cloud Shell was blocked by its weekly quota, so both changes were made by hand in the Console:

| Time (CEST) | Change | Revision |
|---|---|---|
| about 08:08 | ingress set to `internal-and-cloud-load-balancing` (a service-level setting) | none (stays `cma-ingest-00008`) |
| 08:15 | `INGEST_PUBLIC_URLS` = `https://ingest.pulse4all.app,<both run.app URLs>` | `cma-ingest-00009` |

HubSpot's retries delivered the backlog: 200s from 08:15:43 CEST.

## The next scripted deploy

The next `bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app …` (`docs/ingest/PROD_RUNBOOK.md`
7.1) sets the same values as the Console: `--ingress=internal-and-cloud-load-balancing`, and
`INGEST_PUBLIC_URLS` with `https://ingest.pulse4all.app` first, then the service's own `run.app`
addresses as read from the service. `deploy.sh` replaces every environment variable on each deploy
(`--set-env-vars`), so it keeps nothing the Console set that the script does not set itself.

Since 16 October 2026 `deploy.sh` refuses a prod service deploy without `--front` (exit 2, before any
gcloud call), checked by `ingest/verify/deploy-script.mjs` (README, Decision log, 16 October 2026).
