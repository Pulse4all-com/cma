# Night notes, 11 October 2026 (afternoon and evening): messages in the Workspace, the agent go-live

Written by the build chat while Martin was away. Everything here was built and verified in the chat's own container (a local PostgreSQL 18.6 with `db/00` to `42` in README order, Node 22, the standalone build in mock and in api mode); nothing touched dev, prod, GitHub or a vendor. The code reaches the repository through the Claude Code brief in `BRIEFS.md` (the verified patch is its input); `records/` stays Martin's.

## What was built (one pull request, branch `b12-messages`)

1. **Messages in the Workspace (brief B12, web half).** Migration 0008 was already in dev and prod; this is its screen side.
   - `GET /api/v1/me/messages?since&limit`, `POST /api/v1/me/messages/read`, `POST /api/v1/me/messages/<id>/ack`, `POST /api/v1/messages` (send, `messages.send`), `GET /api/v1/messages/stats?from&to`; `src/lib/messages.ts` (pure: the query, read and send validation with the same rules as `cma.send_message`, the poller's toast and urgent decisions, the browser title) with `verify/messages.mjs` (24 checks).
   - `MessageCenter.tsx` in the Shell's top bar for everyone: a poll every 10 s while the tab is visible and every 30 s hidden, an immediate poll after an own change, the unread badge on the inbox icon and in the browser title, a toast per new message (opens the record link in a new window or the inbox, and reads the message), a desktop notification while the tab is hidden (only when the person granted it from the inbox), and the urgent pop-up: one message at a time, oldest first, a two-tone chime, Esc refused, Acknowledge (A) ends it; a pending urgent message opens on the first poll too.
   - `/messages` (Inbox) as a bare rail page right after Welcome, key 2 for everyone with a role (every key below moved by one for everyone alike); Mark all read (M), Open record in a new window, Acknowledge per urgent message, the desktop-notification button.
   - `/messages/send` for `messages.send` (New message, N, on the inbox): the composer (everyone, teams, a language at a minimum level, named people from the people-whose-time-is-kept list, only clocked in, title, text, urgency) and the sent list of the last 30 days from `cma.message_stats` (recipients, read, confirmed, median time to read).
   - Welcome's Updates card lists the latest five messages with the unread count and a link to the inbox.
   - Postgres data layer: six methods on the 0008 functions; the poll's `since` is shifted by 999 µs because the screen knows milliseconds and the database microseconds (found by the API verifier: the newest message came back on every poll). Mock: three fixture messages per tenant, a synthetic "New deal" alert every three minutes, the mock supervisor, manager and admin now hold `messages.send` as the default ladder does.
2. **The ingest's alert hook (B12, ingest half).** A deal or ticket that arrived by a `created` event carries `writes.alerts`; the core calls `cma.ingest_record_alerts(connection, type, ids)` after the records, at most 500 ids a call, and counts `alerts` in the run's totals. Synthetic events (reconcile, backfill, the second read) are `changed`, so they never alert; the function keeps the age limit and the one-alert-per-record rule. `verify/flow.mjs` gained five cases (a rule plus an agent on tenant one; a deal created now → one alert with the record link, delivered to the holders of `leads.accept`; the same delivery again → nothing; a changed event → nothing; a created event for a deal older than the age limit → nothing; the title and body never hold a deal name).
3. **The Pauses column on My hours** (Martin's decision of 7 October): minutes in non-working statuses next to the working time, with a total; both data layers.
4. **The account id on No access yet.** The page shows the signed-in person their own account id (the value Add a person asks for) with a one-line explanation, so a new agent reads it to the manager. Nothing else changed in the flow: access requests stay out.
5. README: Features 7 (first increment live) and 9 (the Pauses column), the API section (Messages paragraph, the verifier counts), Code, eight Decision log rows, the urgent-message Open decision rewritten, the Last updated line.

## Verification (outputs in `local-records/`)

| Check | Result |
|---|---|
| `npm run typecheck`, `npm run lint` (web) | clean |
| `npm run build` (web) | clean |
| copy | PASS, 585 keys, en and nl |
| corrections 26, csv 15, dashboard 17, live 26, team 18, roster 31, configuration 30, messages 24 | all PASS; all provoked FAIL as they must |
| theme | PASS, 22 pages (Messages and Send a message added) |
| layout | PASS: 1280, 1920, the gate at 1279, navigation for five identities with `/messages` as key 2 |
| API verifier against the local database (mock auth, api data) | `ALL 169 PASS`; `ALL 169 PROVOKED CHECKS FAILED, as they must` (`api.txt`, `api-provoked.txt`) |
| ingest: `npm run lint`, `npm test` | clean; 18, 37, 20, 41 PASS |
| ingest flow verifier | `ALL 67 PASS`; `ALL 67 PROVOKED CHECKS FAILED, as they must` (`ingest-flow.txt`, `ingest-flow-provoked.txt`) |

Not run here: the scheduler verifier (unchanged), the IAP token verifier (unchanged), a Docker build (no change to the Dockerfiles), anything against dev or prod.

## Decisions taken (each in the README's Decision log, to confirm)

- Messages is a rail page right after Welcome, key 2 for everyone; the composer is a button on it, not a rail item.
- The urgent pop-up cannot be dismissed; A acknowledges; a chime from the Web Audio API, no sound file.
- Desktop notifications only after a click on the inbox's button, never asked on load.
- Polling 10 s / 30 s as the README's fallback; the realtime service choice stays open.
- The ingest alerts on `created` events only; the database decides the rest.
- No alert rule is seeded: the first rule is a Studio statement at go-live (`GO_LIVE_RUNBOOK.md`); a configuration screen for rules is an Open decision.
- The composer's people list is the people-whose-time-is-kept list; teams and languages come from the catalogs.
- My hours shows a Pauses column.

## Left for the morning

- Merge the pull request (Claude Code brief `B12w` in `BRIEFS.md`), watch the prod build, then the go-live steps in `GO_LIVE_RUNBOOK.md` (the alert rule and the record links in prod Studio, Arno and the first agents on People, the IAP-only grants, `min-instances=1`, the Gemini audit before the gate opens).
- Follow-ups, each a brief in `BRIEFS.md`: B11 (intake reports in the Workspace), the alert-rules configuration screen, quiet hours.
- Open: whether a supervisor should see the people list of the composer by name (today: the same list as Team hours), and whether agents may message their supervisor (an assist request; Features 7 names it for later).
