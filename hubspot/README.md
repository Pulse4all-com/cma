# HubSpot project apps: CMA ingest dev and CMA ingest prod

The HubSpot side of the intake track (README Decision log, 10 October 2026; `docs/night-2026-10-10/DESIGN.md` §2). Each environment has one app built on HubSpot's developer platform, as a project with static auth and private distribution. **No legacy private app is used.** Both apps are rendered from one template:

| | `CMA ingest dev` | `CMA ingest prod` |
|---|---|---|
| Installed in | the developer test account `CMA dev` only, by **Test install** | the live portal, by **Standard install** |
| Webhooks go to | dev's `cma-ingest`: `/hubspot/<dev connection key>` | prod's `cma-ingest`: `/hubspot/<prod connection key>` |

There are two apps because a project's webhook target URL is set for the whole app, not per install.

Files:
- `template/` holds the project: `hsproject.json`, `src/app/app-hsmeta.json` and `src/app/webhooks/webhook-hsmeta.json`. The `{{placeholders}}` stand only for values that differ per environment.
- `env/dev.json` and `env/prod.json` hold the uid suffix, the app name, the target URL (a placeholder until `cma-ingest` is deployed and the connection key exists) and `maxConcurrentRequests` (10). They hold no portal ids, tokens or secrets.
- `render.mjs` writes `build/<env>/`, which is git-ignored. `--target-url` sets the URL without editing a file. It refuses the placeholder unless you pass `--draft`, which writes `build/<env>-draft/` instead, so a draft is never in the directory you upload.
- `verify/render.mjs` is the pure verifier: `node hubspot/verify/render.mjs` (ALL n PASS) and `node hubspot/verify/render.mjs --provoke` (ALL n PROVOKED CHECKS FAILED).

## What the configuration was checked against (10 October 2026)

`developers.hubspot.com` is not reachable from the Claude Code session, so the schema and scope names were checked against HubSpot's own published sources instead:

- **Project and file shapes.** These come from `github.com/HubSpot/hubspot-project-components` (commit `233e986`, 8 September 2026), folder `2026.09`:
  - `defaultFiles/hsproject.json`: `name`, `srcDir`, `platformVersion: "2026.09"`;
  - `components/app/static-private`: `type: "app"`, `distribution: "private"`, `auth.type: "static"`, `requiredScopes`, `optionalScopes`, `conditionallyRequiredScopes`, `permittedUrls`;
  - `components/webhooks`: `type: "webhooks"`, `settings.targetUrl`, `settings.maxConcurrentRequests`, `subscriptions.crmObjects`, `legacyCrmObjects` and `hubEvents`, each entry with `subscriptionType`, `objectType`, `propertyName` and `active`.
- **Where 2026.09 stands.** HubSpot's project parser (`@hubspot/project-parsing-lib` 0.23.3/0.23.4) lists 2026.09 as a supported platform version (2026.03 is what it suggests by default; 2027.03 exists only as a beta).
- **Rendered draft.** The parser's offline translation (schema fetch skipped) reads `build/dev-draft` as one `APPLICATION` and one `WEBHOOKS` component that depends on it, with no skipped files. Every key in the rendered files also occurs in HubSpot's 2026.09 templates. We leave out the template's `support` block (support contact details) and its legacy subscriptions.
- **Event types and scopes.** These come from `github.com/HubSpot/HubSpot-public-api-spec-collection` (2026-09 rollouts, commit of 9 October 2026):
  - the app webhooks API lists `object.creation`, `object.deletion`, `object.merge`, `object.restore`, `object.propertyChange`, `object.associationChange` and `contact.privacyDeletion`;
  - each endpoint the ingest calls names its scope (table below).
- **Still unproven offline.** The schema itself is served by HubSpot at upload time, so `hs project upload` is the final check. Nothing is installed if it fails. One point is unproven until then: whether the project schema accepts `call` as a `crmObjects` object type together with `object.associationChange`.

## Scopes

| Scope | Why | Source (2026-09 spec) |
|---|---|---|
| `oauth` | the base scope HubSpot's project templates put on every app | project templates |
| `crm.objects.deals.read` | deals: batch read, search; deal pipelines | Deals, Pipelines |
| `tickets` | tickets: batch read, search; ticket pipelines | Tickets, Pipelines |
| `crm.objects.contacts.read` | contacts; also **calls**: the calls batch read and search name this scope | Contacts, Calls |
| `crm.objects.contacts.write` | the contact write-back (DESIGN §4.3a), limited to `writeback_field` in the database and in code | Contacts batch update |
| `crm.objects.owners.read` | owners, to map HubSpot owners to CMA people once | Owners |
| `forms` | the form catalog and the submissions poll | Forms |

Two things to know:

- **`tickets` also allows writing tickets.** HubSpot has no read-only ticket scope: in the spec, create, update, merge and delete of tickets all require the same `tickets` scope as reading them. The CMA never writes tickets; Martin accepted the scope on 10 October 2026 (README Decision log). The verifier allows exactly `crm.objects.contacts.write` and `tickets` as write-capable scopes, so adding any other one fails it.
- **Call dispositions need no extra scope, as far as could be checked.** The outcome catalog endpoint (`/calling/v1/dispositions`) is not in the published specs, and no separate scope is requested for it. If the first catalog read answers 403, the scope it names gets added here.

## Subscriptions and their canonical kinds

All 36 are `crmObjects` (`object.*`), active. The one `hubEvents` entry is `contact.privacyDeletion`. No `legacyCrmObjects` are needed. The list is exactly VENDOR_SETUP.md §1.3, and the verifier compares it.

| Object | Subscription | Canonical kind (0006) |
|---|---|---|
| deal, ticket, call | `object.creation` | `created` |
| deal, ticket, contact, call | `object.deletion` | `deleted` |
| deal, ticket, contact | `object.merge` | `merged` |
| deal, ticket | `object.restore` | `restored` |
| deal: `pipeline`, `dealstage`, `hubspot_owner_id`, `closedate`, `amount` | `object.propertyChange` | `changed` |
| ticket: `hs_pipeline`, `hs_pipeline_stage`, `hubspot_owner_id`, `closed_date` | `object.propertyChange` | `changed` |
| contact: the nine properties of VENDOR_SETUP §1.1 | `object.propertyChange` | `changed` |
| call: `hs_call_status`, `hs_call_disposition`, `hubspot_owner_id` | `object.propertyChange` | `changed` |
| deal, ticket, call | `object.associationChange` | `associated` |
| contact | `contact.privacyDeletion` (hubEvents) | `deleted`, plus `cma.ingest_contact_forget()` |

Association changes can't be narrowed to one associated type in the configuration: the app webhooks API has no such filter. The ingest service keeps deal → contact, ticket → contact, call → contact and call → deal and ignores the rest.

## Render, upload, install (Martin, in Cloud Shell)

The full sequence, with the connection and the secrets, is in `docs/night-2026-10-10/MORNING_RUNBOOK.md` §2.2 to §2.5 for dev and in its prod phase for prod.

**1. Install the HubSpot CLI and sign in.**

**Terminal** (in `~/cma`)
```bash
npm install -g @hubspot/cli@8.15.0 >/dev/null 2>&1; hs --version
hs account auth
```
Expected: `8.15.0` (the newest release at least 14 days old on 10 October 2026). `hs account auth` asks for a personal access key: open the link it prints in the **live portal**, generate the key and paste it at the prompt. Projects live in the live portal's Development area, also for the dev app.

**2. Render the environment with its real target URL.** `<URL>` is the `cma-ingest` URL; `<key>` is the connection key from `cma.upsert_connection`. The key isn't a secret: the signature is the proof.

**Terminal** (in `~/cma`)
```bash
node hubspot/render.mjs dev --target-url "<URL>/hubspot/<key>"
```
Expected: `rendered dev: hubspot/build/dev`, then the upload command. Run the same with `prod` for prod. Without `--target-url` it answers `refused: target URL still the placeholder` and writes nothing.

**3. Upload.**

**Terminal** (in `~/cma`)
```bash
cd hubspot/build/dev && hs project upload && cd ~/cma
```
Expected: the build and deploy of project **CMA ingest dev** succeed. If HubSpot refuses a field, it names it; nothing is installed. Upload only from `build/dev` or `build/prod`, never from a `-draft` directory.

**4. Install.**

**Browser:**
- **Dev:** live portal → Development → Projects → CMA ingest dev → the app → Distribution → **Test installs** → Install in `CMA dev`. **Never Standard install** for the dev app.
- **Prod:** live portal → Development → Projects → CMA ingest prod → the app → Distribution → **Standard install**, in the live portal. Only when the runbook's prod phase says so.

Review the scopes on the consent screen: the read scopes, `tickets`, and write on contacts.

## The client secret and the static token

The two values go straight into Secret Manager with the runbook's `put_secret`, a hidden prompt that never echoes them. Never paste them into a file, a chat, a PR or another command.

| Value | Where HubSpot shows it | Secret (DESIGN §5) |
|---|---|---|
| Client secret (signs the webhooks, `X-HubSpot-Signature-v3`) | the app → **Auth** tab | `ingest-hubspot-<env>-signing` |
| Static access token (the read-back, the write-back) | the installed app (the test install for dev, the standard install for prod) | `ingest-hubspot-<env>-token` |

**Terminal** (in `~/cma`, after the runbook's `put_secret` helper is defined)
```bash
put_secret p4a-cma-dev ingest-hubspot-dev-signing
put_secret p4a-cma-dev ingest-hubspot-dev-token
```
Expected: `stored ingest-hubspot-dev-signing (version added)` and the same for the token, nothing else. For prod use `p4a-cma-prod` and `ingest-hubspot-prod-…`. Then grant the accessor to `cma-ingest`'s service account as in runbook §2.4.

## The first delivery: the signature headers

The ingest service authenticates on `X-HubSpot-Signature-v3` with `X-HubSpot-Request-Timestamp` (DESIGN §2). HubSpot's documentation does not confirm that project apps send v3, so check it on the first delivery in dev (runbook §2.5). Create a deal in `CMA dev`, then:

**Terminal**
```bash
gcloud run services logs read cma-ingest --project=p4a-cma-dev --region=europe-west4 --limit=30 | grep -E "hubspot|signature|header" | tail -10
```
Expected: accepted requests (200). If the service was deployed with `INGEST_LOG_HEADER_NAMES=1`, it logs the header names only, never their values, and they include `x-hubspot-signature-v3` and `x-hubspot-request-timestamp`.

If v3 is missing, stop. The fallback is decided (Decision log, 10 October 2026): webhooks off, and the reconcile job every two minutes. It is a schedule change, not a weaker signature.
