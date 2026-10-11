# Go-live runbook, Monday 12 October 2026: the first agents with Arno

What the morning needs, in order. Every block says where it runs. Nothing here touches the pulse4all.com organisation: all changes stay inside the CMA folder's two projects and the two databases.

## 0. Before anything: the pull request

**Terminal** (Cloud Shell, `~/cma`):
```bash
git fetch origin && git checkout b12-messages && git log --oneline -3
```
Expected: the top commit "Messages in the Workspace (B12), the Pauses column, the account id on No access". If the branch is not there yet, the Claude Code brief `B12w` in `BRIEFS.md` creates it from the patch.

**Terminal** (`~/cma/web`):
```bash
npm ci && npm run typecheck && npm run lint && npm run build && npm run verify
```
Expected: clean, then `copy: PASS (585 keys …)`, `ALL 26 PASS`, `ALL 15 PASS`, `ALL 17 PASS`, `ALL 26 PASS`, `team: PASS (18 checks)`, `roster: PASS (31 checks)`, `ALL 30 PASS`, `ALL 24 PASS`, then theme and layout need the local mock server (README, Code) and may be skipped: both passed in the night (`NIGHT_NOTES.md`).

**Terminal** (`~/cma/web`, dev through the proxy, as in README Verification):
```bash
gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 &
node verify/api.mjs
```
Expected: `ALL 169 PASS` once dev runs the merged image; before the merge dev still runs the old image and the 22 messaging checks are 404s, so run this after step 2.

**Terminal** (`~/cma/ingest`):
```bash
npm ci && npm run lint && npm test
```
Expected: clean; `ALL 18 PASS`, `ALL 37 PASS`, `ALL 20 PASS`, `ALL 41 PASS`.

## 1. Merge and build

**Browser:** GitHub → `Pulse4all-com/cma` → the pull request → Squash and merge.

**Terminal** (`~/cma`):
```bash
git checkout main && git pull && gcloud builds list --project=p4a-cma-prod --limit=3 --format='table(id,status,substitutions.SHORT_SHA,createTime)'
```
Expected: a build for the merge's short SHA, `SUCCESS` after a few minutes; then `workspace.pulse4all.app` shows Messages as rail item 2 and the inbox icon in the top bar.

**Terminal** (`~/cma`, the ingest with the alert hook, dev then prod):
```bash
bash docs/ingest/deploy.sh dev
bash docs/ingest/deploy.sh prod
```
Expected: the image built in prod as `cma-build`, deployed to both; `/health` answers the new short SHA.

## 2. Prod configuration: the alert rule and the record links

**Studio (cma-prod-pg)**, the context block (prod uses you):
```sql
set role cma_owner;
select t.slug, t.id as tenant_id, u.id as user_id, u.email
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
reset role;
```
Then, with the two ids:
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
```

**Studio (cma-prod-pg)**, the Pulse4all Subscriptions rule (every counted deal pipeline; the agents clocked in with the market's language; the fallback to `leads.manage`; normal urgency; the age limit from `alerts.max_age_minutes`, 60):
```sql
select cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal', null);
```
Expected: one uuid.

**Studio (cma-prod-pg)**, the record links on the live HubSpot connection (first read what the connection holds, because `set_connection_settings` replaces all settings):
```sql
select c.id, c.name, c.settings from cma.integration_connection c where c.adapter = 'hubspot';
```
Then, with every key the row already has repeated:
```sql
select cma.set_connection_settings('<connection id>', '{"app_host":"app-eu1.hubspot.com","record_url_deal":"https://{app_host}/contacts/{account}/record/0-3/{id}","record_url_ticket":"https://{app_host}/contacts/{account}/record/0-5/{id}"}'::jsonb);
reset role;
```
Expected: an empty result. Skip this block while the prod HubSpot connection does not exist yet (Next in the carry-over: the prod phase for HubSpot); the rule alone does no harm.

**Browser** (the first message, as yourself): `workspace.pulse4all.app` → Messages (2) → New message (N) → To: Everyone → title `Welcome to the Workspace` → Send. Expected: "Sent to n people", the message in the sent list, and in your own inbox nothing (a sender is not a recipient unless the target includes them: Everyone does, so it is there, unread).

## 3. People: Arno and the first agents

Arno and each agent need a `pulse4all.com` Google account (README, Authentication) and their account id, which `workspace.pulse4all.app` now shows them on the No access yet page after they sign in (step 4 must have let them through IAP first). The other way to the id: **Browser** → `admin.google.com` → Users → the user → the address bar holds `/ac/users/<id>`; that number is the account id.

**Browser** (`workspace.pulse4all.app`, as yourself, People → Add a person (A)):
- Arno: name, `arno@pulse4all.com`, employer Pulse4all, role `manager` (he holds `messages.send`, `monitoring.live`, `workday.team`, `roster.manage`; `admin` only if he is to configure statuses and links), provider `google`, his account id, zone `Europe/Amsterdam`.
- Each agent: name, their address, employer `newco`, role `agent`, provider `google`, their account id, zone `Europe/Madrid`. Then Edit person → teams (Team NL, …) and skills (the language levels, Sales), because the alert rule routes on the market's language at its minimum level: an agent without the language skill never receives a new-deal alert.

Expected after each: the row on People, Active, "clock runs".

## 4. IAP: let the agents through without the domain gate

Before the gate opens to the whole domain, each agent passes IAP through an IAP-only grant on the backend (README, Open decisions, Roles in prod), never through `cma@pulse4all.com`.

**Terminal** (one line per person; prod project):
```bash
gcloud iap web add-iam-policy-binding --project=p4a-cma-prod --resource-type=backend-services --service=cma-web-backend --member='user:arno@pulse4all.com' --role='roles/iap.httpsResourceAccessor'
```
Expected: the policy printed with the new member. Repeat per agent address. Check:
```bash
gcloud iap web get-iam-policy --project=p4a-cma-prod --resource-type=backend-services --service=cma-web-backend
```

## 5. The service stays warm

**Terminal** (a few euros a month; decided for the gate in the README):
```bash
gcloud run services update cma-web --project=p4a-cma-prod --region=europe-west4 --min-instances=1
```
Expected: a new revision, `min-instances: 1` in the service description. Note that the next web merge keeps it only if `cloudbuild.yaml`'s deploy step does not reset it: check with `gcloud run services describe cma-web --project=p4a-cma-prod --region=europe-west4 --format='value(spec.template.metadata.annotations)'` after the first merge that follows, and add `--min-instances=1` to the deploy step if it was lost (say so in the PR).

## 6. The Gemini audit before the gate opens

Re-upload `README.md` to the Gem after the merge, then paste:

```
Audit the Contactcenter-Management-App before its first external users: Newco agents sign in to workspace.pulse4all.app from tomorrow. Scope: project p4a-cma-prod only, inside folder Contactcenter-Management-App; never advise changes at organisation level or to Mark's or Joshua's access. Check, with the exact gcloud command you would use to verify each point and the README section it rests on: (1) IAP on cma-web-backend admits only cma@pulse4all.com plus named pulse4all.com users with roles/iap.httpsResourceAccessor, nothing broader; (2) cma-web's ingress is internal-and-cloud-load-balancing and the run.app address refuses direct visits; (3) the Cloud SQL instance cma-prod-pg has no public authorised networks, connector enforcement on, PITR on, and only the three service accounts plus the team's IAM users as database users; (4) the new Cloud Run jobs ingest-sweep, ingest-poll-forms, ingest-reconcile, ingest-backfill run as cma-ingest@ and are invoked only by cma-ingest-scheduler@ with run.invoker on those jobs; (5) Secret Manager: the HubSpot secrets are readable by cma-ingest@ only; (6) logging: no request bodies or personal data in cma-web and cma-ingest logs, retention as the README states; (7) min-instances=1 on cma-web and its cost. Answer per point: finding, severity, the command, the README section, and accept / reject / needs a decision. Put the answer in the Google Doc "CMA - Gemini audit findings" under a heading with today's date.
```

Then here: "read the latest findings" and we classify them.

## 7. With Arno in the room: the five minutes per agent

1. Sign in at `workspace.pulse4all.app` with the pulse4all.com account → Welcome → Clock in.
2. My day (3): the status buttons, S then arrows then Enter; Break and Lunch stop the clock.
3. Messages (2): the inbox; press the desktop-notification button once and allow it; Arno sends an urgent test message to that person and they see the pop-up and press A.
4. My hours (4): today's row with the Pauses column.
5. Log out (L) at the end of the day: it ends the workday.

`AGENT_GUIDE.md` is the one-page version for the agents.

## 8. What to watch on day one

- Live board (Arno): who is on which status; a day forgotten past midnight is closed by the scheduler and flagged on Team hours.
- Messages → Send a message: the sent list shows read counts and the median time to read; that is the first measure of how fast agents see something.
- The alert rule fires only for deals the ingest sees: until the prod HubSpot connection and its webhooks exist (carry-over: the prod phase for HubSpot), Arno's manual messages are the only messages.
- Data protection: the heads-up to Yordi is still the open item in the README; the new store is unchanged (messages hold references only), but agents' hours and names now land in prod.
