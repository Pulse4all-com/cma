# Trusted Shops reviews in prod, 25 October 2026 (phase 13)

Phase 13 of `docs/ingest/PROD_RUNBOOK.md` (brief B18, addition 0008ze, `Pulse4all-com/cma#192`), run by Martin on
25 October 2026 in p4a-cma-dev and p4a-cma-prod for Pulse4all Subscriptions. Written down by Claude Code at Martin's
request from his report of the runs (brief B18.1); the values below are his. Ids, counts, dates and times only, as
reported: no key, no secret, no client secret, no email address and no name of a person.

## 13.1 Dev: the migration and its verifies

- `104_reviews.sql` and seed `02` ran clean.
- `105_verify_reviews.sql`: 27 PASS; provoked 0 PASS, 27 FAIL.
- Again after `104`: `103` 12 PASS, `101` 18 PASS, `79` 13 PASS, `75` 24 PASS, `41` PASS; `99` 33 PASS.

## 13.2 The data map

`docs/datamap/schema.json` refreshed from dev at `0008ze` (87 tables, 126 views), commit `3420d18` on the pull
request's branch.

## 13.3 Prod: the migration

- Point-in-time recovery on.
- `0008zc` and `0008zd` present before the run.
- `104` and seed `02` ran clean.
- The read-only check: `true | true | true`; the rule Negative review present and off.

## 13.4 The merge

Merged as `03d7fc4`; the web revision `cma-web-00092-rgk`.

## 13.5 The API client and its secret

- API client `CMA prod ingest`, identifier `CMAprodIngest`: the account's last of its 5 client slots.
- Client id `9b3bfe12ca88__CMAprodIngest`.
- Secret Manager: `ingest-trustedshops-subs-token`.
- The first secret was exposed in a terminal command and rotated the same day: a new secret in eTrusted, stored as
  version 2; version 1 destroyed.

## 13.6 The ingest

`cma-ingest-00014-mtm` on `03d7fc4`; the job `ingest-poll-reviews` scheduled at minute 7.

## 13.7 The connection

- Connection `01a172e1-7201-7c4e-9dbf-a0db5d7c81ef`.
- External account id `9b3bfe12ca88`: the client id's prefix, because eTrusted shows no separate account id.
- `crm_connection_id`: the live portal's HubSpot connection.

## 13.8 The first poll

Succeeded: 41 fetched and 41 upserted; 7 channels; links: order 14, contact 27.

## 13.9 The channels

DE, FR, NL, AT, SE and GB mapped to their market and counted. The channel for defibserviceplus.com left without a
market and off.

## 13.10 The backfill

- Execution `ingest-backfill-g9ncq`, 12:51 to 13:00.
- 845 reviews: UK 411 (since October 2023), NL 241 (since November 2023), DE 191 (since February 2025), FR 1, SE 1,
  AT 0.
- Links: order 16, contact 782, none 45. These three add up to 843, two fewer than the 845 reviews; the report does
  not say where the other two are.
- About 9 of the run's minutes went to the HubSpot contact lookups.

## The check against the eTrusted Control Centre

- The Control Centre counts the reviews in the states APPROVED and MODERATION and leaves out REJECTED:
  - UK: 395, the 395 approved; the 16 rejected are not counted (411 held).
  - NL: 241, 240 approved and 1 in moderation.
  - DE: 191.
- The Control Centre's score is the simple average of the APPROVED reviews submitted in the last 12 months:
  DE 4.71 = 4.71, NL 4.77 = 4.77, UK 4.83 against 4.82 (it appears to cut to two decimals rather than round).
  Reports → Reviews averages the selected period, so it differs by design.
- Paging worked over the 845 reviews and 7 channels at 60 requests a minute without a 429.

## Finding: a transaction reference held an email address

1 of the 845 reviews held an email address as its transaction reference: 24 characters, no invite event type, a
manual invite of 16 June 2024. 0008ze stored it in `cma.review.transaction_ref` and in `raw.transaction.reference`.
Brief B18.1 (addition 0008zf, `db/106_review_reference_guard.sql`) addresses it; its run in dev and prod is recorded
separately.
