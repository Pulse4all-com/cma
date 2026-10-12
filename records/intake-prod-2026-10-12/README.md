# HubSpot into cma-ingest in prod, 12 October 2026

`docs/ingest/PROD_RUNBOOK.md` 7.1 to 7.8, run by Martin on 12 October 2026 in p4a-cma-prod. Written
down by Claude Code at Martin's request from his report of the run; the numbers and ids below are
his. No secret, connection key or email address appears here.

## Service and front (7.1, 7.2)

- `cma-ingest` at `https://ingest.pulse4all.app` through the web load balancer, revision 3 on image
  `40164b4`, ingress `internal-and-cloud-load-balancing`; the `run.app` address answers 404.
- `front.sh`: `cma-ingest-backend` was created without `--protocol` after `add-backend` refused the
  HTTPS backend ("Port name is not supported for a backend service with Serverless network endpoint
  groups"); `docs/ingest/front.sh` now does the same.
- `40164b4` was a fresh build of unchanged `ingest/` source after a docs merge; `deploy.sh` now tags
  the image by the last commit under `ingest/`.
- The four jobs (`ingest-sweep`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-backfill`) deployed
  and scheduled with `deploy.sh prod --jobs`.

## Connection and app (7.3, 7.4)

- Connection `01a12f17-4fcb-7406-b0ff-b335c54f828a` (adapter `hubspot`) on the live portal 147946837.
- App **CMA ingest prod**, Standard install in the live portal.
- Market ES (Spain, Europe/Madrid, EUR) added: the live portal has ES forms. No Spanish language
  skill, so ES has no skill link.

## First events (7.5, 7.5b)

- `deal_country` is filled in the live portal: `United Kingdom` resolved to `GB`, source `record`.
- Deletions arrive within seconds (`deal` `deleted`, `processed`).
- Webhook to urgent alert with the record link proven end to end.
- Call outcomes: connected unless the label matches not reached, voicemail, no answer, busy, wrong
  number, incorrect data or email only; `Left live message` not connected; `Do Not Call Or Email`
  connected.
- Forms: counted when the name matches quote, contact or info and not cancellation, replacement or
  support; `lead_source` `quote`, `contact` or `info`; market from the name's two-letter prefix
  (UK → GB).

## Owners and the assignment rule (7.6, 7.7)

- HubSpot owners mapped to CMA persons (system `hubspot_owner`).
- Rule **Assigned deal** `01a12f64-4e43-73e6-ac93-34026b3fe22a` and the record links.
- Seen in prod: an assignment alert read "assigned 10:17" on a message stamped 11:17 (a GB deal,
  London time); migration 0008c shows alert times in the tenant's zone.

## Backfill from 1 October (7.8)

| Object | Records |
|---|---|
| deal | 1359 |
| ticket | 1520 |
| crm_call | 2784 |
| form_submission | about 320 |

- Executions: `ingest-backfill-l4tmf`, `ingest-backfill-nv5kc`, `ingest-backfill-zbrtr`,
  `ingest-backfill-xv6m7`.
- The backfill selects by last modification since `--from`, so records created before 1 October
  but touched since then are included.

## Build

- Cloud Build trigger run `89bbac6e-f0ca-4ae0-bdcd-495348c0cd3a`.
