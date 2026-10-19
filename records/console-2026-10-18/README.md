# Console changes in prod, 18 October 2026

What changed in `p4a-cma-prod` outside the repository on 18 October 2026, after the ninth Gemini audit of that
afternoon: the project's audit configuration for Secret Manager, three new alert policies, and a check that
Query Insights was not switched on. All times UTC. Written down by Claude Code on 18 October 2026 at Martin's
request from the terminal output he pasted into the session (Claude Code session of N19-B, backlog CMA-069);
the values are his. Ids, settings, dates and times only: no key, no secret and no personal data (account
addresses are left out). The terminal output itself is not in this folder.

## Secret Manager audit configuration

| When | Command (Martin's terminal) | Result |
|---|---|---|
| before 14:55 | `gcloud projects get-iam-policy p4a-cma-prod --flatten="auditConfigs[].auditLogConfigs[]" --filter="auditConfigs.service:secretmanager.googleapis.com" --format=yaml` | `WARNING: The following filter keys were not present in any resource : auditConfigs.service`: the project's IAM policy held no audit configuration at all |
| 14:55:37 | the ninth Gemini audit's recommendation 1: the project's IAM policy exported, its `auditConfigs` set to Secret Manager's `DATA_READ` and `DATA_WRITE`, the policy written back with `gcloud projects set-iam-policy p4a-cma-prod` | `Updated IAM policy for project [p4a-cma-prod].`, the bindings as exported (16 roles; `roles/cloudsql.client` and `roles/cloudsql.instanceUser` still hold `cma-ingest`, `cma-nocodb` and `cma-web`), `version: 1` |
| after | `gcloud projects get-iam-policy p4a-cma-prod --format="yaml(auditConfigs)"` | `secretmanager.googleapis.com`: `DATA_READ`, `DATA_WRITE` |
| after | `gcloud resource-manager folders get-iam-policy 641665155313 --format="yaml(auditConfigs)"` | `null`: the folder sets none |

The Admin Activity log has the change as a `SetIamPolicy` entry at 2026-10-18T14:55:37.608432Z with an empty
`policyDelta` (`{}`), as are the six other `SetIamPolicy` entries of the two days before (17 October 13:37:44
and 13:37:47; 18 October 03:47:00, 03:47:03, 03:47:29 and 03:47:32). That field does not show a change of the
audit configuration, so it cannot tell whether one was made.

README (Environments and infrastructure) recorded this logging as set in the console on 13 October 2026; the
project held none until 14:55 on 18 October. Dev was not checked.

## Alert policies

Before 14:59 the project had one policy, `cma-ingest 429` (created 2026-10-13T20:19:21Z by `docs/ingest/alert.sh`).
`gcloud monitoring channels` is not in gcloud's GA track; `gcloud beta monitoring channels list` shows one
channel, `CMA ingest alerts`, type `email`, enabled (`projects/p4a-cma-prod/notificationChannels/6981213391921458476`).
Martin created three policies from JSON files with `gcloud monitoring policies create --policy-from-file`, each
to that channel:

| Policy | Id | Created | Condition |
|---|---|---|---|
| `cma-prod-pg connections above 75 of 93` | `7826240071609075818` | 2026-10-18T14:59:29Z | `cloudsql.googleapis.com/database/postgresql/num_backends`, `resource.labels.database_id = "p4a-cma-prod:cma-prod-pg"`; mean per 60 s, summed by `resource.label.database_id`; above 75 for 120 s |
| `cma-web more than 5 server errors in 5 minutes` | `2704411180648151660` | 2026-10-18T14:59:58Z | `run.googleapis.com/request_count`, `cloud_run_revision`, `service_name = "cma-web"`, `response_code_class = "5xx"`; delta per 300 s, summed by `resource.label.service_name`; above 5, duration 0 s; auto-close 1800 s |
| `Cloud Run job failed (any job)` | `5008424809395648009` | 2026-10-18T15:00:31Z | `run.googleapis.com/job/completed_execution_count`, `cloud_run_job`, `result = "failed"`; delta per 600 s, summed by `resource.label.job_name`; above 0, duration 0 s; auto-close 1800 s |

The connections policy carries no auto-close of its own. The 5xx policy got its auto-close in a second update
with the whole policy: the first, with `alertStrategy` alone, was refused (`INVALID_ARGUMENT: Request was missing
field alert_policy.display_name`). Martin checked the three metrics' descriptors through the Monitoring API:
`run.googleapis.com/request_count` labels `response_code`, `response_code_class`, `route`, `DELTA`, `INT64`;
`run.googleapis.com/job/completed_execution_count` label `result`, `DELTA`, `INT64`;
`cloudsql.googleapis.com/database/postgresql/num_backends` label `database`, `GAUGE`, `INT64`.

`gcloud monitoring policies list` afterwards: the four policies, each enabled, each with one notification channel.

## The first alert: `cma-refresh-follow-up` at 16:04

`Cloud Run job failed (any job)` opened for `cma-refresh-follow-up` (incident start 16:09 in its email) and
resolved by itself. The job's lines with `severity>=WARNING` over the day:

| Time | Severity | Line |
|---|---|---|
| 14:22:19.263 and 14:22:19.440 | `WARNING` | one line per tenant, reason `running`: a refresh found the tenant's lock held by the run before it and skipped it |
| 16:04:17.352 | `ERROR` | `Error: read ECONNRESET at TLSWrap.onStreamRead (node:internal/stream_base_commons:216:20)` |
| 16:04:17.413 | `WARNING` | `Container called exit(1).` |
| 16:04:23.655 | `ERROR` | no fields |

One failed execution in the day: the database connection was reset and the job's process ended, the next minute
succeeded. No tenant line and no `failed` run row were written for it, so the reset happened outside a refresh's
query (an idle pooled connection or a connect).

## Query Insights: not switched on

`gcloud sql operations list --instance=cma-prod-pg --project=p4a-cma-prod --limit=10`: only `BACKUP_VOLUME`
operations from 12 to 18 October (the latest 2026-10-18T01:57:28 to 01:58:59) and a `CREATE_USER` on
12 October; no `UPDATE`. The ninth Gemini audit's recommendation 4 (`gcloud sql instances patch cma-prod-pg
--insights-config-…`) was not run, and nothing changed the instance on 18 October.
