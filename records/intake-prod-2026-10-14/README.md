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

## Rollout to 13 stores

The other 13 stores, run by Martin on 14 October 2026 after the NL pilot, several stores at once
(`docs/ingest/PROD_RUNBOOK.md` 9.6, Several stores at once). Written down by Claude Code from his
report, as above: ids and counts only, no webhook address key and no customer data.

### The app and the source-name lookup (9.3, 9.6)

- The app installed on 14 stores.
- Every store uses Juo (`9548333057` and `subscription_contract_checkout_one`). IE, NO, ES, FI, CH
  and IT had no orders in the 60 days: no sales yet (confirmed).

### Connections and stores (9.6)

| Handle | Market | Currency | Time zone | Connection id |
|---|---|---|---|---|
| `pulse4all` | GB | GBP | Europe/London | `01a139b6-8546-7b0d-9f41-f235b19c24af` |
| `pulse4all-at` | AT | EUR | Europe/Vienna | `01a139b6-8550-7a37-b295-f2d37a7ec1b4` |
| `pulse4all-be` | BE | EUR | Europe/Brussels | `01a139b6-854c-74be-aa6a-aac4846f2ebd` |
| `pulse4all-ch` | CH | CHF | Europe/Zurich | `01a139b6-8555-7d94-9caf-e5063559ed64` |
| `pulse4all-de` | DE | EUR | Europe/Berlin | `01a139b6-8553-7650-8fe8-6e4f77fe5382` |
| `pulse4all-dk` | DK | DKK | Europe/Copenhagen | `01a139b6-854e-7f48-8d77-7c41aea144e3` |
| `pulse4all-esp` | ES | EUR | Europe/Madrid | `01a139b6-8554-7b2d-bb3c-e5165817a152` |
| `pulse4all-fi` | FI | EUR | Europe/Helsinki | `01a139b6-8555-7493-8544-ba0b867bf218` |
| `pulse4all-fr` | FR | EUR | Europe/Paris | `01a139b6-8552-7cf2-8c4a-2e7caa96a58c` |
| `pulse4all-ie` | IE | EUR | Europe/Dublin | `01a139b6-854d-7b38-a13c-72ca5cecc1a8` |
| `pulse4all-ita` | IT | EUR | Europe/Rome | `01a139b6-8556-7659-8897-0f905a28c018` |
| `pulse4all-no` | NO | NOK | Europe/Oslo | `01a139b6-8554-708b-8c8c-a51a3f68dac7` |
| `pulse4all-se` | SE | SEK | Europe/Stockholm | `01a139b6-8551-7ef1-84e5-ff16234649ef` |

Store names `Pulse4all <market>`, connection names `Shopify Pulse4all <market>`; every connection
with the same `client_id` as NL, `api_version` `2026-10` and the same `crm_connection_id` as NL.

### Renewal settings (9.6)

| Setting | Value |
|---|---|
| `commerce.renewal_source_names` | `9548333057,subscription_contract_checkout_one` |
| `commerce.renewal_app_ids` | empty |

Replaces the NL value above (`9548333057` alone): the `subscription_contract_checkout_one` orders are
Juo renewals paid through Shopify, not checkout orders (README Decision log, 14 October 2026).

### Subscriptions (9.7)

- 7 topics per store, 91 in total; all present on a rerun.

### Backfill (9.8)

- From 1 October 2026: 2 `backfill` runs `succeeded` per store.
- Events `failed`: 0. Outbox actions: 0.

### Bridge check (9.8)

| Market | Customers | With a contact link | Share |
|---|---|---|---|
| GB | 5,741 | 5,644 | 98.3% |
| NL | 1,875 | 1,831 | 97.7% |
| DE | 1,608 | 1,571 | 97.7% |
| FR | 803 | 788 | 98.1% |
| SE | 633 | 602 | 95.1% |
| BE | 376 | 370 | 98.4% |
| AT | 170 | 161 | 94.7% |
| DK | 27 | 23 | 85.2% |
| IE | 23 | 23 | |
| FI | 3 | 3 | |
| ES | 1 | 1 | |
| IT | 1 | 1 | |
| NO | 1 | 1 | |
| CH | 0 | | |

### Orders per kind after the renewal change (9.8)

| Market | First | Repeat | Renewal |
|---|---|---|---|
| GB | 72 | 35 | 1,099 |
| DE | 33 | 6 | 242 |
| NL | 11 | 0 | 493 |
| FR | 12 | 1 | 55 |
| SE | 9 | 0 | 46 |
| BE | 2 | 2 | 39 |
| AT | 2 | 0 | 16 |
| DK | 1 | 0 | 1 |

IE, NO, ES, FI, CH and IT: no orders (no sales yet).

### Not in the report (rollout)

- The source-name lookup's lines and counts per store (9.6).
- The sync runs' times and fetched counts (9.8).
- The orders per kind per day per store (9.8) and the day-one checks (9.9).
