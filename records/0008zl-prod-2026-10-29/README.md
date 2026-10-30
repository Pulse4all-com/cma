# Juo subscriptions in prod, the GB pilot, 29 October 2026 (phase 15)

Phase 15 of `docs/ingest/PROD_RUNBOOK.md` (brief B20, addition 0008zl, `Pulse4all-com/cma#207`), run by Martin on
29 October 2026 in p4a-cma-dev and p4a-cma-prod for Pulse4all Subscriptions, with a spot check and the day-one count
on 30 October 2026. Written down by Claude Code at Martin's request from his report of the runs; the values below are
his. Ids, counts, dates and times only, as reported: no key, no secret, no customer data and no Juo subscription id.

## (a) Dev, 29 October 2026

- `118_subscriptions.sql` ran.
- `119_verify_subscriptions.sql`: 23 PASS; provoked 23 FAIL.
- Again after `118`: `115` 14 ok, `105` 27 PASS, `107` 10 PASS, `53` 16 PASS.

## (b) The data map

98 tables, 147 views.

## (c) Prod, 29 October 2026

- Point-in-time recovery on, 7 days.
- `cma.schema_migration`: `0008zl` after `0008zk`.
- `118` ran in 689 ms.
- `115`: 14 ok; its C1 8,913 ms of 10,000.
- `105` refused: it is dev only. The runbook was corrected in `31dd4ff` (prod runs `115` only after `118`).

## (d) The merges

- `Pulse4all-com/cma#207` merged as `5c85798`; Cloud Build trigger `cma-web-main`, build `9671b03b`: SUCCESS.
- `Pulse4all-com/cma#204` and `Pulse4all-com/cma#205` (qs 6.17.0) merged; build `d70ebb1d`: SUCCESS.
- `Pulse4all-com/cma#208` merged.

## 15.1 The Gemini audit and the key

- The Gemini audit of 29 October 2026: FIND-01 to FIND-05 accepted, its commands rejected (Decision log, 29 Oct 2026).
- The key: the GB store's existing dedicated key, named "JUO API Key"; no new key made.

## 15.2 The secret, the ingest and the accessor

- Secret `ingest-juo-pulse4all-key`, version 1.
- Only `cma-ingest` holds `secretAccessor` on it.
- The ingest and its 10 jobs on `0f0ddf3`; health ok; `run.app` 404.

## 15.3 The GB store in the CMA

Store `pulse4all`, GB, GBP; Shopify connection `01a139b6-8546-7b0d-9f41-f235b19c24af`; 5,840 customers.

## 15.4 The connection

- Connection **Juo GB** `01a18603-3368-7e25-a448-dc10bade752f`, kind `subscriptions`.
- Settings: every 5 minutes, 2 requests a second.
- The store link: ok.

## 15.5 The dry run of the subscriptions

| Count | Value |
|---|---|
| fetched | 4,090 |
| mapped | 4,090 |
| unreadable | 0 |
| statuses | active 3,037, canceled 656, expired 8, failed 374, merged 9, paused 6 |
| instrument known | 4,090 |
| without customer | 0 |
| customers unmatched | 0 |
| requests | 41 |

## 15.6 The dry run of the events

From 2024-01-01; the log's `from` at 23:00Z, midnight in Amsterdam.

| Count | Value |
|---|---|
| fetched | 230,726 |
| mapped | 63,697 |
| other type | 167,029 |
| unreadable | 0 |
| kept | renewed 34,265, renew_failed 25,160, status_changed 4,268, canceled 2, reactivated 2 |
| reason dropped | 246 |
| requests | 2,308 |

## 15.7 The backfills

- The events: 05:22 to 05:42 UTC, succeeded.
- The subscriptions: 05:42 to 05:43 UTC, succeeded; inserted 4,090, `missing_now` 0.

## 15.8 The checks

- The subscriptions per status as 15.5; without customer 0, instrument unknown 0.
- The first events: `renewed` 2025-05-14, `status_changed` 2026-01-28.
- The payment states: paid 2,823, in_retry 214, failed 374, paused 6, canceled 664; the 9 merged subscriptions have
  none.
- `subscriptions_with_an_email` 0 and `events_with_an_email` 0. Martin ran both checks with `\.` in the pattern; he
  reports that the runbook's `\\.` never matches.
- Spot check, 30 October 2026: 3 `in_retry` subscriptions match Juo (active, payment failed, retries 1).

## 15.9 The schedule and day one

- `ingest-poll-subscriptions`: ENABLED, `*/5`, Europe/Amsterdam, from 29 October 2026 05:55 UTC.
- Day one, to 30 October 2026 about 10:40 local time: 288 `subscriptions_poll` succeeded, 1 `reconcile` succeeded,
  0 failed.

## Juo's own figures, 29 October 2026

Juo's Analytics cards (last 30 days): active 3,070, paused 6, failed 405, cancelled 526. The figures of 26 October
2026 (836/125/166/4) came from a partial listing.
