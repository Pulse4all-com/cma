# Shopify NL into cma-ingest in prod, 14 October 2026

`docs/ingest/PROD_RUNBOOK.md` phase 9 for the NL store, run by Martin on 14 October 2026 in
p4a-cma-prod: the first walk-through of phase 9. Written down by Claude Code at Martin's request from
his report of the run; the numbers and ids below are his. Ids and counts only: no secret, no webhook
address key, and no customer's name, email address, phone number or address appears here. The client
id is not a secret (9.3).

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

## Connection and store (9.6)

Created and configured on 14 October 2026 in Studio (`cma.upsert_connection`,
`cma.set_connection_kind`, `cma.set_connection_settings`):

| Field | Value |
|---|---|
| Connection id | `01a1389a-bae5-777c-9d6f-a2637e58fd16` |
| Adapter | `shopify` |
| Kind | `commerce` (Shop on the Sources page) |
| Name | Shopify Pulse4all NL |
| Account id | `pulse4all-nl.myshopify.com` |
| Signing secret name | `ingest-shopify-app-signing` |
| Access secret name | none |
| `client_id` | `7fe3ddfd27637e2304d6f792fb3ef29e` |
| `api_version` | `2026-10` |
| `shop_handle` | `pulse4all-nl` |
| `crm_connection_id` | `01a12f17-4fcb-7406-b0ff-b335c54f828a` (the HubSpot connection of `records/intake-prod-2026-10-12`) |

The store row, added on Configuration → Sources:

| Handle | Name | Market | Currency | Time zone |
|---|---|---|---|---|
| `pulse4all-nl` | Pulse4all NL | NL | EUR | Europe/Amsterdam |

## Renewal settings (9.6)

The source-name lookup (`shopify-subscribe.mjs --source-names --days 60`), the Juo lines:

```
876	9548333057	9548333057	Juo Subscriptions
…	subscription_contract_checkout_one	9548333057	…
```

The second line carries Juo's app id too, but its orders are checkout orders, not renewals.

| Setting | Value |
|---|---|
| `commerce.renewal_source_names` | `9548333057` |
| `commerce.renewal_app_ids` | empty (the app id is shared with the checkout orders) |

## Subscriptions and first events (9.7)

- `shopify-subscribe.mjs`: 7 subscriptions created (`CUSTOMERS_CREATE`, `CUSTOMERS_UPDATE`,
  `CUSTOMERS_DELETE`, `ORDERS_CREATE`, `ORDERS_UPDATED`, `ORDERS_CANCELLED`, `ORDERS_DELETE`).
- First deliveries: two `orders/updated`, both `processed`.
- Shopify's webhook failure rate for the app: 0%.
- The app's error rate in the Dev Dashboard: about 51%. Shopify answers `CmaOrders` with a partial
  `ACCESS_DENIED` (the order's own phone withheld); the orders are complete.

## Backfill (9.8)

`cma.sync_run`, job `backfill`, from 1 October 2026:

| Stream | Status | Started (UTC) | Finished (UTC) | Error | Fetched | Stale | Failed |
|---|---|---|---|---|---|---|---|
| `commerce_customer` | succeeded | 2026-10-14 04:17:38 | 2026-10-14 04:30:31 | empty | not captured | 0 | 0 |
| `commerce_order` | succeeded | 2026-10-14 04:48:25 | 2026-10-14 04:49:10 | empty | not captured | 0 | 0 |

## Orders per kind per day (9.8)

NL, 1 to 14 October 2026, from Reports → Intake ("This month", the organisation's business days);
the totals match the database.

| Date | First | Repeat | Renewal |
|---|---|---|---|
| 1 Oct | 1 | 3 | 2 |
| 2 Oct | 0 | 5 | 125 |
| 3 Oct | 1 | 1 | 4 |
| 4 Oct | 0 | 2 | 0 |
| 5 Oct | 1 | 4 | 32 |
| 6 Oct | 0 | 3 | 35 |
| 7 Oct | 1 | 2 | 22 |
| 8 Oct | 1 | 3 | 14 |
| 9 Oct | 0 | 5 | 19 |
| 10 Oct | 1 | 0 | 1 |
| 11 Oct | 1 | 4 | 0 |
| 12 Oct | 2 | 0 | 8 |
| 13 Oct | 1 | 3 | 187 |
| 14 Oct | 0 | 0 | 7 |
| **Total** | **10** | **35** | **456** |

New customers in the same view: 21. The three kinds add up to 501 orders, the order count below.
The two largest renewal days are 2 and 13 October (125 and 187 of 456).

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

## Not captured

- The fetched counts of the two backfill sync runs (9.8).
- The count of the `subscription_contract_checkout_one` line and the other sales channels' lines of
  the source-name lookup (9.6).
