# HubSpot end to end in dev, 11 October 2026

Runbook phase 2.2 to 2.5 (`docs/night-2026-10-10/MORNING_RUNBOOK.md`), run by Martin on 11 October 2026.
What was observed, as reported from the HubSpot screens, Cloud Shell, the `cma-ingest` logs and
Cloud SQL Studio on cma-dev-pg. No secret value appears here or was shown on screen.

## HubSpot project and install

- Project **CMA ingest dev** in the live portal 147946837.
- Build #1 refused: the scope `tickets` is retired. Build #2, after PR #90 (`crm.objects.tickets.read`),
  deployed both components, including the webhooks component with `call` and
  `object.associationChange`.
- App id 56597629, static auth, private distribution.
- Test install in `CMA dev` 149511908 (developer test account, eu1), with 7 granted scopes.

## Secrets

- `ingest-hubspot-dev-signing` and `ingest-hubspot-dev-token` in p4a-cma-dev, with
  `roles/secretmanager.secretAccessor` for `cma-ingest`.
- The token verified with `GET /account-info/v3/details`: 149511908, `DEVELOPER_TEST`, eu1. The value
  was never shown.

## Ingest service

- `cma-ingest` on `c1216e7` in dev.
- The first POSTs, at 13:17:09 UTC, were answered 200: the `X-HubSpot-Signature-v3` signature was accepted.

## Database (cma-dev-pg)

`cma.ingest_event`, all `processed`:

| Object | created | changed | associated |
|---|---|---|---|
| deal | 1 | 4 | 2 |
| crm_call | 1 | 3 | 6 |

- `cma.crm_record`: deal 525374864614, pipeline 4209185980 (label Sales test), not closed, contact
  887422569709.
- `cma.crm_contact`: NL / nl / EUR.
- `cma.crm_association`: deal → contact, crm_call → contact, crm_call → deal.
- `cma.record_market_of` for the deal: NL, source contact (`deal_country` empty).

## Call outcomes

- The call outcome catalog was read without an extra scope: 7 outcomes (Busy, Connected, Left live
  message, Left voicemail, Meeting booked, No answer, Wrong number).
- Set in dev with `cma.set_call_outcome`: Connected and Meeting booked `is_connected` true; the other
  five false.

## Speed to lead

`cma.speed_to_lead_of` for the deal:

| Field | Value |
|---|---|
| market | NL (contact) |
| first call | 526267934935 at 13:21:57Z |
| first_call_linked | false (no Aircall yet) |
| first_connected_at | 13:21:57Z |
| agent_ref | 37920127, from the call (the owner is not mapped to a CMA person yet) |
| elapsed | 289 s |
| business | 0 s (Sunday) |
| target | 3600 |
| within_target | true |
| next_business_noon | 2026-10-12T10:00Z |
| before_next_noon | true |
