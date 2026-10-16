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
  - each endpoint the ingest calls names its scope (table below); on 11 October 2026 HubSpot refused `tickets` on the first upload, and the ticket calls were checked again (Scopes).
- **Still unproven offline.** The schema itself is served by HubSpot at upload time, so `hs project upload` is the final check. Nothing is installed if it fails. One point was unproven until then: whether the project schema accepts `call` as a `crmObjects` object type together with `object.associationChange`. It does: build #2 of CMA ingest dev deployed the webhooks component with both (11 October 2026).

## Scopes

| Scope | Why | Source (2026-09 spec) |
|---|---|---|
| `oauth` | the base scope HubSpot's project templates put on every app | project templates |
| `crm.objects.deals.read` | deals: batch read, search; deal pipelines | Deals, Pipelines |
| `crm.objects.tickets.read` | tickets: batch read, search; their contacts through the associations batch read; the ticket webhook subscriptions | named by HubSpot's refusal of `tickets` (11 October 2026); see below |
| `crm.objects.contacts.read` | contacts; also **calls**: the calls batch read and search name this scope | Contacts, Calls |
| `crm.objects.contacts.write` | the contact write-back (DESIGN §4.3a), limited to `writeback_field` in the database and in code | Contacts batch update |
| `crm.objects.owners.read` | owners, to map HubSpot owners to CMA people once; since brief B17b also the email poll's owner map (an owner's user id → owner id, hourly), because an inbox conversation names its agent by user id | Owners |
| `forms` | the form catalog and the submissions poll | Forms |
| `sales-email-read` | email engagements (brief B17b): the search and the batch read, together with `crm.objects.contacts.read` | `PublicApiSpecs/CRM/Emails/Rollouts/424/2026-09/emails.json`: the batch read and the search name `crm.objects.contacts.read` and `sales-email-read` in one requirement, so both are needed. Not `crm.objects.emails.read`: the API accepts it (`GET /crm/v3/objects/emails` without an email scope answered `MISSING_SCOPES` with `requiredGranularScopes` `crm.schemas.emails.read`, `crm.objects.emails.read`, `sales-email-read`, "one or more of"), but it is not available to this app without HubSpot support: build #4 of CMA ingest dev, which requested it, failed to deploy on 15 October 2026 with "The scope crm.objects.emails.read isn't available to this app. If your app needs it, contact HubSpot support to request access." |
| `conversations.read` | inbox conversations (brief B17b): inboxes, channels, channel accounts, threads, a thread's messages | `PublicApiSpecs/Conversations/Conversations/Rollouts/54902/v3/conversations.json` (and its 2026-09 rollout): every read names `conversations.read` |

Things to know:

- **The email poll's two read scopes (brief B17b, 15 October 2026).** `sales-email-read` and `conversations.read` let the app read email content (subjects, bodies, addresses); the ingest asks only for metadata and drops what a conversation message brings at once (`docs/ingest/README.md`, section Email). Yordi agreed to both on 15 October 2026 (README Decision log). HubSpot accepted `sales-email-read` on a 2026.09 project app: build #3 of CMA ingest dev deployed with it, and the dev test install answers 200 on `/crm/v3/objects/emails` and on `/conversations/v3/conversations/inboxes` (15 October 2026). The granular `crm.objects.emails.read`, which the newer emails rollout (`PublicApiSpecs/CRM/Emails/Rollouts/321895/2026-09/emails.json`) lists among 80 alternatives, is not available to this app without HubSpot support (the Scopes table); `sales-email-read` stays until HubSpot grants it. No `conversations.write` and no `crm.objects.emails.write`: the CMA never writes either.

- **Ticket scopes: read only (11 October 2026).** The first upload of `CMA ingest dev` on 11 October 2026 was refused: "The scope tickets has been replaced by more specific scopes and is no longer available. Use the following scope(s) instead: crm.objects.tickets.read, crm.objects.tickets.write, crm.schemas.tickets.read, crm.schemas.tickets.write." The CMA never writes tickets, so the app requests `crm.objects.tickets.read` only, and `crm.objects.contacts.write` is its only write scope. This supersedes the acceptance of `tickets` of 10 October 2026 (README Decision log). The verifier fails on `tickets` and on any `*.write` or `*.delete` scope other than `crm.objects.contacts.write`.
- **What the spec says about the ticket calls (checked 11 October 2026, `HubSpot-public-api-spec-collection` commit `c7c63ae`).** The published spec lags behind the platform: `crm.objects.tickets.read` occurs in none of its files, and the 2026-09 ticket specs still name `tickets`. In OpenAPI each entry of `security` is an alternative, so one listed scope is enough:

  | Call (ingest) | Spec file (`PublicApiSpecs/…`) | Line | Ticket scope listed |
  |---|---|---|---|
  | `POST /crm/v3/objects/tickets/batch/read` | `CRM/Tickets/Rollouts/424/v3/tickets.json` | 341 | none (`security: []`) |
  | same, 2026-09 | `CRM/Tickets/Rollouts/424/2026-09/tickets.json` | 762 | `tickets` |
  | `POST /crm/v3/objects/tickets/search` | `CRM/Tickets/Rollouts/424/v3/tickets.json` | 527 | none (`security: []`) |
  | same, 2026-09 | `CRM/Tickets/Rollouts/424/2026-09/tickets.json` | 974 | `tickets` |
  | `GET /crm/v3/pipelines/tickets` | `CRM/Pipelines/Rollouts/145896/v3/pipelines.json` | 65 | none outside the sensitive variants; any of 98 alternatives, among them `crm.objects.deals.read` and `crm.objects.contacts.read` |
  | same, 2026-09 | `CRM/Pipelines/Rollouts/321972/2026-09/pipelines.json` | 59 | the same 98 alternatives; `crm.schemas.tickets.read` is not among them |
  | same, 2026-09-beta | `CRM/Pipelines/Rollouts/321972/2026-09-beta/pipelines.json` | 59 | `tickets` or `crm.schemas.tickets.read`, as two of 100 alternatives |
  | `POST /crm/v4/associations/tickets/contacts/batch/read` | `CRM/Associations/Rollouts/130902/v4/associations.json` | 1173 | none outside the sensitive variants; any of 79 alternatives, among them `crm.objects.contacts.read` |
  | ticket webhook subscriptions | `Webhooks/Webhooks/Rollouts/147891/2026-09/webhooks.json` | 248 | none: the subscriptions API takes the developer key; its error format names `missingScopes` (line 2191) |

  So no spec version lists `crm.schemas.tickets.read` as needed, and it is not requested. If the ticket pipelines read answers 403 at runtime, the ingest logs `catalog refresh skipped` (deal and ticket pipelines are refreshed together) and keeps processing events; then add `crm.schemas.tickets.read`, a read scope the verifier allows once it is in the documented set. Not needed: in dev on 11 October 2026 the pipeline label resolved, so the refresh was not skipped (README Decision log).
- **`forms` also covers form definitions.** HubSpot has one forms scope: the spec (`Marketing/Forms/Rollouts/144909/v3/forms.json`) names `forms` for reading forms and for creating, updating and deleting them. The CMA only reads the catalog and the submissions.
- **Tasks need no extra scope (addition 0008n, 16 October 2026).** HubSpot's tasks API (`PublicApiSpecs/CRM/Tasks`, the batch read and the search the ingest uses) names `crm.objects.contacts.read`, which the app holds, so the task subscriptions and reads come with a new app version in both portals but no scope change; the install is updated or reinstalled only when HubSpot asks or the task events do not arrive (`docs/ingest/PROD_RUNBOOK.md` 11.2). The read asks for eight structural properties and never `hs_task_body` or `hs_task_subject`; the database strips any text key regardless (`cma.task_raw`).
- **Call dispositions need no extra scope.** The outcome catalog endpoint (`/calling/v1/dispositions`) is not in the published specs, and no separate scope is requested for it. Confirmed in dev on 11 October 2026: the catalog was read with the app's scopes, 7 outcomes (README Decision log).

## Subscriptions and their canonical kinds

All 46 are `crmObjects` (`object.*`), active (37 until addition 0008n added the nine task subscriptions on 16 October 2026). The one `hubEvents` entry is `contact.privacyDeletion`. No `legacyCrmObjects` are needed. The list is exactly VENDOR_SETUP.md §1.3, and the verifier compares it.

| Object | Subscription | Canonical kind (0006) |
|---|---|---|
| deal, ticket, call | `object.creation` | `created` |
| deal, ticket, contact, call | `object.deletion` | `deleted` |
| deal, ticket, contact | `object.merge` | `merged` |
| deal, ticket | `object.restore` | `restored` |
| deal: `pipeline`, `dealstage`, `hubspot_owner_id`, `closedate`, `amount` | `object.propertyChange` | `changed` |
| ticket: `hs_pipeline`, `hs_pipeline_stage`, `hubspot_owner_id`, `closed_date` | `object.propertyChange` | `changed` |
| contact: the nine properties of VENDOR_SETUP §1.1, and `country_dropdown` (since brief B17b: the contact's country slot 2, a property HubSpot has and the CMA does not create) | `object.propertyChange` | `changed` |
| call: `hs_call_status`, `hs_call_disposition`, `hubspot_owner_id` | `object.propertyChange` | `changed` |
| deal, ticket, call | `object.associationChange` | `associated` |
| contact | `contact.privacyDeletion` (hubEvents) | `deleted`, plus `cma.ingest_contact_forget()` |
| task | `object.creation` | `created` (addition 0008n, 16 October 2026) |
| task | `object.deletion` | `deleted` |
| task: `hs_task_status`, `hs_timestamp`, `hubspot_owner_id`, `hs_task_completion_date`, `hs_task_type`, `hs_task_priority` | `object.propertyChange` | `changed`; never `hs_task_body` or `hs_task_subject` |
| task | `object.associationChange` (task ↔ contact, deal, ticket) | `associated`: the task is read back with its first contact, deal and ticket |

Association changes can't be narrowed to one associated type in the configuration: the app webhooks API has no such filter. The ingest service keeps deal → contact, ticket → contact, call → contact and call → deal and ignores the rest.

## Render, upload, install (Martin, in Cloud Shell)

The full sequence, with the connection and the secrets, is in `docs/night-2026-10-10/MORNING_RUNBOOK.md` §2.2 to §2.5 for dev and in its prod phase for prod. The steps below were corrected to what happened in dev on 11 October 2026 (`records/hubspot-dev-2026-10-11`).

**1. Install the HubSpot CLI and sign in.** Install it under the home directory, so it survives a Cloud Shell restart without changing npm's global prefix: Cloud Shell's Node is managed by `nvm`, which refuses a global prefix.

**Terminal** (once per Cloud Shell home)
```bash
npm install --prefix ~/.hscli-bin @hubspot/cli@8.15.0 >/dev/null 2>&1
grep -q '.hscli-bin' ~/.bashrc || echo 'export PATH="$HOME/.hscli-bin/node_modules/.bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.hscli-bin/node_modules/.bin:$PATH"
hs --version
```
Expected: `8.15.0` (the newest release at least 14 days old on 10 October 2026). In a later session the `PATH` line in `~/.bashrc` is enough.

**Terminal**
```bash
hs account auth
```
Expected: a prompt for a personal access key. It must be a personal access key of the **live portal**: open the link the CLI prints in the live portal, generate the key and paste it at the prompt. Projects live in the live portal's Development area, also for the dev app. The CLI's login stays in `~/.hscli`.

**Terminal**
```bash
hs account list
```
Expected: the live portal, with the developer test account under it as `↳ … [test account]`.

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
Expected: the upload names the live portal, then the build and deploy of project **CMA ingest dev** succeed with both components (the app and the webhooks). **If the upload line names the test account, answer `n`.** If HubSpot refuses a field or a scope, it names it and nothing is installed (11 October 2026: build #1 was refused for the retired `tickets` scope, build #2 deployed after PR #90). Upload only from `build/dev` or `build/prod`, never from a `-draft` directory.

**4. The client secret, before the install.** See the next section.

**5. Install.**

**Browser:**
- **Dev:** live portal → Development → Projects → CMA ingest dev → the app → Distribution → **Test installs** → **Add test install(s)** → tick the test account `CMA dev` → install. **Never "Install now" under Standard install** for the dev app: that is the live portal.
- **Prod:** live portal → Development → Projects → CMA ingest prod → the app → Distribution → **Standard install**, in the live portal. Only when the runbook's prod phase says so.

Review the scopes on the consent screen: the read scopes (ticket read among them, no ticket write) and write on contacts.

**6. The static token**, then the accessor grants (next section).

## The client secret and the static token

The two values go straight into Secret Manager with the runbook's `put_secret`, a hidden prompt that never echoes them. Never paste them into a file, a chat, a PR or another command.

| Value | Where HubSpot shows it | Secret (DESIGN §5) | When |
|---|---|---|---|
| Client secret (signs the webhooks, `X-HubSpot-Signature-v3`) | the app → **Auth** tab (with the scopes) | `ingest-hubspot-<env>-signing` | before the install |
| Static access token (the read-back, the write-back) | the app → **Distribution** tab → the install's row → **Show** (for dev, the test install's row); not on the Auth tab | `ingest-hubspot-<env>-token` | after the install |

Define `put_secret` (runbook, Helpers) in the same Cloud Shell session as the command that uses it. Run each `put_secret` on its own line, typed or pasted alone, not inside a pasted block: the hidden prompt would take the block's next line as the value.

**Terminal** (in `~/cma`, the client secret copied from the Auth tab)
```bash
put_secret p4a-cma-dev ingest-hubspot-dev-signing
```
Expected: `stored ingest-hubspot-dev-signing (version added)`, nothing else.

**Terminal** (after the install, the token copied from the Distribution tab)
```bash
put_secret p4a-cma-dev ingest-hubspot-dev-token
```
Expected: `stored ingest-hubspot-dev-token (version added)`, nothing else. For prod use `p4a-cma-prod` and the prod secret names of the runbook's prod phase.

Verify the token without showing it:

**Terminal**
```bash
gcloud secrets versions access latest --secret=ingest-hubspot-dev-token --project=p4a-cma-dev | sed 's/^/Authorization: Bearer /' \
  | curl -s -H @- https://api.hubapi.com/account-info/v3/details | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("portalId"), d.get("accountType"), d.get("dataHostingLocation"))'
```
Expected for dev: the test account's id, `DEVELOPER_TEST`, `eu1`. For prod: the live portal's id. Then grant the accessor to `cma-ingest`'s service account as in runbook §2.4.

## The first delivery: the signature headers

The ingest service authenticates on `X-HubSpot-Signature-v3` with `X-HubSpot-Request-Timestamp` (DESIGN §2). HubSpot's documentation did not confirm that project apps send v3; the first delivery in dev did (11 October 2026: `cma-ingest` answered the first POSTs with 200, README Decision log), so the reconcile fallback is not needed. To check a new environment's first delivery (runbook §2.5), create a deal in the installed account, then:

**Terminal**
```bash
gcloud run services logs read cma-ingest --project=p4a-cma-dev --region=europe-west4 --limit=30 | grep -E "hubspot|signature|header" | tail -10
```
Expected: accepted requests (200). If the service was deployed with `INGEST_LOG_HEADER_NAMES=1`, it logs the header names only, never their values, and they include `x-hubspot-signature-v3` and `x-hubspot-request-timestamp`. A 401 means the signature did not verify: check that the signing secret is the client secret of this app.
