# Claude Code briefs, 11 October 2026

Paste a brief (from its `---` line to the next) into a new Claude Code on the web session on `Pulse4all-com/cma`. The standing instructions of `docs/night-2026-10-10/BRIEFS.md` apply (push early, a draft PR as soon as one verifier passes, no secrets or real data, nothing hardcoded, the PR description with the acceptance results).

---

## B12w. Messages in the Workspace, assignment alerts and automation messages (0008a), the Pauses column, the account id on No access (one PR)

Sonnet is enough. The work is done and verified in a build chat (`docs/night-2026-10-11/NIGHT_NOTES.md`); this session puts it in a pull request.

**Route A, the patch.** Martin gives you a URL and a sha256 of `b12-messages.patch` (a `git format-patch` of two commits on top of `main` at `e95c8e5`: the messages increment and the 0008a increment). In the session:

```bash
git fetch origin && git checkout -b b12-messages origin/main
curl -fsSL -o /tmp/b12-messages.patch '<URL>'
sha256sum /tmp/b12-messages.patch      # must equal the sha256 Martin gave
git am --3way /tmp/b12-messages.patch
```
Then run, in `web/`: `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build`, `npm run verify:copy`, `verify:corrections`, `verify:csv`, `verify:dashboard`, `verify:live`, `verify:team`, `verify:roster`, `verify:configuration`, `verify:messages`, each normal and with `--provoke`; in `ingest/`: `npm ci`, `npm run lint`, `npm test`. Push the branch and open the PR with the title `Messages in the Workspace (B12), assignment alerts and automation messages (0008a), the Pauses column, the account id on No access`; the description says that Martin runs `44` and `45` in dev and prod (`records/0008a-*`) before the assignment rule exists. If `git am` fails or the sha256 differs, stop and say so; do not guess.

**Route B, without the patch** (only if Route A is impossible): build the same thing from this specification and the night notes, in this order, one commit per step: (1) `web/src/lib/data/types.ts` messaging types and five `CmaData` methods, `postgres.ts` on `cma.my_messages` (with `since` shifted by `+ interval '999 microseconds'`), `my_unread_count`, `mark_messages_read`, `acknowledge_message`, `send_message` (answering the recipient count from `cma.message_stats`) and `message_stats`; `mock.ts` with three fixture messages per tenant, a synthetic alert every three minutes and `messages.send` on the mock supervisor, manager and admin; (2) `web/src/lib/messages.ts` (pure: `parseInboxQuery`, `parseIds`, `parseSendInput` with the rules of `cma.send_message`, `arrivals`, `titleWithUnread`, `fmtSeconds`) with `web/verify/messages.mjs` (24 checks, `--provoke`); (3) the routes `GET /api/v1/me/messages?since&limit`, `POST /api/v1/me/messages/read`, `POST /api/v1/me/messages/[id]/ack`, `POST /api/v1/messages` (201), `GET /api/v1/messages/stats?from&to` (92 days), every write behind `assertSameSiteWrite`; (4) `MessageCenter.tsx` in the Shell's top bar (poll 10 s visible / 30 s hidden, immediate poll on the `cma-messages-changed` event, unread badge and `document.title`, toasts, desktop notification only when permission is already granted, the urgent `<dialog>` with `onCancel` prevented, a Web Audio chime and Acknowledge with `data-shortcut="a"`), `Inbox.tsx` and `src/app/messages/page.tsx` (rail page after Welcome, `permission: null`, icon `inbox`; Mark all read M; New message N for `messages.send`), `MessageComposer.tsx` and `src/app/messages/send/page.tsx` (redirect to `/messages` without `messages.send`; the people list from `listTeamPeople` when `workday.team` is held; the sent list of the last 30 days); the Updates card on Welcome from `listMyMessages(me, null, 5)`; `nav.ts` with `ShellPage` `"messages" | "messages-send"` and `NavHref` `"/messages"`; copy keys `nav.messages`, `messages.*`, `welcome.updatesMore`, `welcome.updatesMoreOne`, `welcome.openMessages` in en and nl; (5) the verifiers: `verify/layout.mjs` expects `/messages` as the second href for every identity, `verify/theme.mjs` adds `/messages` and `/messages/send` (supervisor), `verify/api.mjs` gains the 22 messaging checks of the night notes; (6) the Pauses column: `HoursDay.pauseMinutes` from the non-working intervals of the day in Postgres and from clock-in to clock-out minus working time in the mock, a column and total on `/hours`, copy `myHours.pauses`; (7) the account id on `/no-access` from `getIdentity()` (email and subject, with `noAccess.accountLabel`, `idLabel`, `idHint` in both locales); (8) the ingest: in `ingest/src/adapters/hubspot/read.mjs` a record group with a `created` event sets `writes.alerts = [{ recordType, sourceId }]`; `ingest/src/core/store.mjs` `writeAll` calls `cma.ingest_record_alerts($1, $2, $3::text[])` per record type in chunks after the forgets and counts `alerts`; `ingest/verify/flow.mjs` gains the five alert cases (a rule on tenant one, an agent with `leads.accept`, a deal created now in the fake, the record-url settings repeated with `phone_default_region`, two deliveries because the flow admin holds `leads.accept` too, and `crm_record` count 3 at the end); (9) README as in `NIGHT_NOTES.md` (Features 7 and 9, the API section, Code, nine Decision log rows, the urgent-message Open decision, Last updated).

The second commit adds: `db/44_assignment_alerts.sql` and `db/45_verify_assignment_alerts.sql` (addition 0008a, README Data model: assignment alerts and automation messages), `ingest/src/adapters/automation/` with the `/automation/<key>` route in `server.mjs`, `writes.assignments` in the HubSpot read-back and `cma.ingest_assignment_alerts` in `store.mjs`, twelve flow-verifier cases (79), the alert ping in `MessageCenter.tsx` and the clock warning on `/logout` with its copy.

**Acceptance** (both routes): typecheck, lint, build clean; copy 586 keys; the pure verifiers 26, 15, 17, 26, 18, 31, 30, 24 PASS and provoked FAIL; ingest `npm test` 18, 37, 20, 41 PASS. Martin runs theme, layout, the API verifier (169) and the flow verifier (67) himself.

**README** is part of the patch; nothing to add unless a step above was changed.

---

## B11. Web: intake reports

Standing instructions apply. Sonnet. Depends on nothing further: 0007d is in dev and prod.

Goal: DESIGN §7 (`docs/night-2026-10-10/DESIGN.md`) reports in the Workspace: two Dashboard cards (speed to lead today: median business minutes and % within target; new customers and first orders today), Report → Speed to lead (period bar, grouping by day, market, agent, pipeline, the summary table, the open-not-called list with deal id, market, pipeline, age in business minutes and the record link icon; no names), Report → Intake (per day and market from `cma.intake_per_day`, sparklines, tagged calls per tag and direction, orders first, repeat and renewal per store), Data → Data quality (the checks of `cma.data_quality()` with counts and record links for the team). Routes `GET /api/v1/reports/speed-to-lead?from&to&group`, `GET /api/v1/reports/speed-to-lead/rows`, `GET /api/v1/reports/intake?from&to`, `GET /api/v1/reports/data-quality`, each with the permission of its function (`reports.view` or `performance.team`; data quality also `tenant.configure`). Copy in both locales, mock data for all of it, the existing theme tokens and components (`Card`, `PeriodBar`, the Dashboard's SVG charts). Rail: the two reports join the Reports group after Dashboard; Data quality is a page of a new Data group (`reports.view` or `tenant.configure`) after Reports and before Configuration, so no agent key moves.

Files: `web/src/lib/reports.ts` (pure: groupings, sparkline points, the age formatting) with `web/verify/reports.mjs`; data-layer methods on Postgres (`cma.speed_to_lead_summary`, `speed_to_lead_rows`, `intake_per_day`, `data_quality`) and mock; the routes; the pages; `verify/api.mjs` gains the routes with their refusals; `verify/layout.mjs` and `verify/theme.mjs` the new pages.

Acceptance: as the standing instructions; the API verifier against a local database with `db/00` to `42` and a small fixture (invented ids, as `41_verify_lead_metrics.sql` builds one).

README: Features 5 notes the first reports; the API section lists the routes; Roadmap step 6 marks I7 done; Last updated.

---

## B14. Configuration: alert rules

Standing instructions apply. Sonnet. Depends on B12w merged.

Goal: a sixth Configuration screen, Alert rules (`/configuration/alert-rules`, `tenant.configure`): the rules of `cma.message_rule` with name, record type (deal, ticket), pipelines (all counted, or chosen from `cma.connection_pipeline` of the tenant's connections), audience permission, match language, only clocked in, fallback permission, urgency, age limit, enabled; add and edit through `cma.upsert_message_rule`, enable and disable through `cma.set_message_rule_enabled`; routes under `/api/v1/configuration/alert-rules`; the list read needs a function: add `cma.message_rules()` (`tenant.configure`) in an addition `0008a` (`db/44_message_rules.sql`, `db/45_verify_message_rules.sql`, blocks A and B with the provoke switch) because 0008 has no read function for rules. Copy in both locales, mock, the configuration verifier and the API verifier extended, theme and layout with the page.

README: Data model addition 0008a, the configuration screen under Features 9 and the API section, the Open decision on the rules screen closed, Last updated.
