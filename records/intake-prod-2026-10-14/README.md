# Shopify NL into cma-ingest in prod, 14 October 2026

`docs/ingest/PROD_RUNBOOK.md` phase 9 for the NL store, run by Martin on 14 October 2026 in
p4a-cma-prod: the first walk-through of phase 9. Written down by Claude Code at Martin's request from
his report of the run; the numbers and ids below are his. Ids and counts only: no secret, connection
key, client id, name, email address, phone number or address appears here.

## Gate

- `cma.schema_migration` in prod: 0008e, 0008f, 0008g and 0008h applied on 13 October 2026 at
  02:48, 07:10, 10:25 and 14:31 UTC (`records/0008e-prod-2026-10-13` to `records/0008h-prod-2026-10-13`).

## The app (9.2, 9.3)

- Created manually in the Dev Dashboard as **CMA ingest**; scopes `read_customers,read_orders`.
- `read_all_orders` was not offered (Shopify serves the last 60 days of orders).
- Embedded off; the form needed an app URL, filled with the placeholder `https://example.com`.
- No API access requests page and no distribution picker: the custom-distribution app got every
  customer field (name, email, phone, address, device data) and the store owner's staff data
  automatically.

## Renewal settings (9.6)

The source-name lookup (`shopify-subscribe.mjs --source-names --days 60`), the Juo lines:

```
876	9548333057	9548333057	Juo Subscriptions
…	subscription_contract_checkout_one	9548333057	…
```

The second line carries Juo's app id too, but its orders are checkout orders, not renewals. Its
count and the other channels' lines are not in Martin's report.

| Setting | Value |
|---|---|
| `commerce.renewal_source_names` | `9548333057` |
| `commerce.renewal_app_ids` | empty (the app id is shared with the checkout orders) |

## First events (9.7)

- The app's error rate in the Dev Dashboard: about 51%. Shopify answers `CmaOrders` with a partial
  `ACCESS_DENIED` (the order's own phone withheld); the orders are complete.

## After the backfill (9.8)

Bridge check:

| Customers | With a contact link | Outbox actions |
|---|---|---|
| 1,874 | 1,830 | 0 |

Phone hash coverage:

| Object | With `phone_hash` | Total |
|---|---|---|
| Orders | 339 | 501 |
| Customers | 911 | 1,874 |

The orders without a hash have the phone only in the shipping address, which the adapter never reads.

## Day one (9.9)

- `cma.lead_to_order_rows()`: 189 deals, 0 with an order.
- Reports → Data quality, `Shop customers without a contact`: 1,874.
- Both read the contacts' Contact-Shopify ID-1/2, not the link of 0008h, and stay there until the
  HubSpot–Shopify app fills those properties.

## Not in Martin's report yet

These outputs of the run belong here and are still to be added from the run itself:

- The connection id of the NL store (9.6).
- The store row: handle, market, currency and time zone (9.6).
- The orders per kind per day for the last 14 days (9.8).
- The sync runs of the two backfills (9.8: job, stream, status, counts, error, times).
