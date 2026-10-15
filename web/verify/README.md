# Verifiers

Verify-by-breaking: every verifier passes on the real app and has a `--provoke`
mode that must fail. Run both when something changes; a verifier that cannot
fail proves nothing.

| Script | Checks | Needs |
|---|---|---|
| `copy.mjs` | Style guide text rules on `src/lib/copy.ts`, all languages | nothing |
| `theme.mjs` | Only palette colours painted (SVG fills and strokes included), Montserrat only, heading and body colours, Tailwind default palette removed; eight pages: Welcome, My day without and with a day (the start route as Agent Two), the Dashboard as the test supervisor; on the report pages one header hint opened by focus, its text Inkt Body on white | app in mock mode, `BASE` |
| `layout.mjs` | 1280 and 1920 px shell, gate at 1279, no horizontal scroll, rail and top bar tokens, keycaps, navigation per identity (everyone lands on Welcome, pages numbered without gaps, Clock in only for a person whose time is kept, My day sends the analyst to Welcome); on the report pages and the Intake row one header hint opened by focus: shown, inside the viewport, not covering its header; the Intake table scrolls inside its card, the main area never sideways at 1280; screenshots to `records/layout/` | app in mock mode, `BASE`, `OUT_DIR` optional |
| `hints.mjs` | Every header of Speed to lead (each grouping), Intake and Data quality and every Dashboard tile has one info mark described by a hint with its values filled in; focus and hover open it, Esc closes it, Tab reaches the next mark, a tap opens and closes it, a tile still opens its report | app in mock mode, `BASE` |
| `dashboard.mjs` | The Dashboard's figures (`src/lib/dashboard.ts`): groups from flags, minutes as Team hours, status order, every day on the axis, people by name, hours axis, palette tokens | nothing (`npm run verify:dashboard`) |
| `reports.mjs` | The intake reports' logic (`src/lib/reports.ts`, B11): the four groups and G, the 92-day bound, percentile_cont and the summary figures as the database computes them, Not mapped for an agent without a mapping, the open deals in waiting order, the not-connected states (telephony and shop figures null, never 0), market order and filter, the inline bars, the data-quality order, the formats; since addition 0008i Inbound and since 0008j Calls and Calls per agent on `63`'s own dataset (the figures `db/63` proves, the filters, the previous period like for like, the deltas, the top twelve tags and Other, the per-agent bars and split), and since 0008k the telephony history start on `65`'s own dataset and what a tile says against a previous span before it and from it on; 75 checks | nothing (`npm run verify:reports`) |
| `follow-up.mjs` | The follow-up layer's logic (`src/lib/follow-up.ts`, addition 0008o, 16 October 2026): the four settings' rules as the database applies them, a pipeline's own response time, the filter from a query and back, the market, person and state filters, the filters' choices, the summary and the per-person rows as `cma.follow_up_summary_of` and `cma.follow_up_by_owner_of` compute them, the person's own rows, Welcome's Needs attention lines, the Live board's tiles, the age bucket in words, the unlinked-calls setting per kind; 24 checks | nothing (`npm run verify:follow-up`) |
| `preview.mjs` | Preview as role (`src/lib/auth/preview.ts`, 16 October 2026): the narrowing is exactly the intersection (a property test over random sets), a role's permission the person lacks never appears, an unknown key and a non-admin's cookie are ignored, an empty intersection is allowed and still lands on Welcome, canPreview for the admin with or without a preview, the cookie's name and 12 hours, which keys are accepted; 20 checks | nothing (`npm run verify:preview`) |
| `api.mjs --reports` | The intake reports' routes only (17 checks): 403 for an agent on each, the supervisor without data quality, the analyst and manager allowed, more than 92 days and a group outside the four 400, no personal field in the rows, the summary adding up to the rows, Not mapped as one group without a label, the figures following the tenant's connections, a tenant without telephony or a shop (`invest-analyst`, where it exists). Runs against mock or api data; the full run includes them | app in mock auth mode, `BASE`; for a local database `reports-fixture.sql` (local only, invented ids) |
| `api.mjs --calls` | Calls and Calls per agent's routes only (addition 0008j, 16 checks, 14 where the `reader` and `invest-analyst` identities do not exist; since 0008k 19 and 17): 403 for an agent on all four, `performance.team` for the per-agent routes and `reports.view` enough for the overview and the tag use, more than 92 days, a group outside the four and a bad market or line 400, no hash, number, call id or telephony user id in any answer, the groups adding up to the total, the previous period like for like (a running period against the same point, an ended one against the whole previous period), the threshold from the settings, a market and a line narrowing all four answers alike, people by name, counted tags per person, a tenant without telephony; since 0008k the history start one date or none for every range, grouping and filter, no call before it and one on its date, a previous span before it with no change and from it on the change as before (a tenant without calls: none, and every span compares). Reads only; runs against mock or api data; the full run includes them | app in mock auth mode, `BASE`; for a local database `reports-fixture.sql` at `db/63` (`db/64` since 0008k) |
| `iap-token.mjs` | IAP token handling: valid, missing, wrong audience or issuer, expired, future issue, wrong signer, spoofed headers | app in iap mode against the script's key set, see file header |

Browser verifiers use Playwright; install its browser once with
`npx playwright install chromium` (Cloud Shell: add `--with-deps`).

```bash
# app in mock mode on 8080, then:
BASE=http://localhost:8080 npm run verify
BASE=http://localhost:8080 npm run verify:layout -- --provoke   # must fail
```

Record the pass output and the screenshots under `records/<increment>-<env>-<date>`
as the Release flow in the repository README asks.
