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
| `reports.mjs` | The intake reports' logic (`src/lib/reports.ts`, B11): the four groups and G, the 92-day bound, percentile_cont and the summary figures as the database computes them, Not mapped for an agent without a mapping, the open deals in waiting order, the not-connected states (telephony and shop figures null, never 0), market order and filter, the inline bars, the data-quality order, the formats; since addition 0008i Inbound and since 0008j Calls and Calls per agent on `63`'s own dataset (the figures `db/63` proves, the filters, the previous period like for like, the deltas, the top twelve tags and Other, the per-agent bars and split); 73 checks | nothing (`npm run verify:reports`) |
| `api.mjs --reports` | The intake reports' routes only (17 checks): 403 for an agent on each, the supervisor without data quality, the analyst and manager allowed, more than 92 days and a group outside the four 400, no personal field in the rows, the summary adding up to the rows, Not mapped as one group without a label, the figures following the tenant's connections, a tenant without telephony or a shop (`invest-analyst`, where it exists). Runs against mock or api data; the full run includes them | app in mock auth mode, `BASE`; for a local database `reports-fixture.sql` (local only, invented ids) |
| `api.mjs --calls` | Calls and Calls per agent's routes only (addition 0008j, 16 checks, 14 where the `reader` and `invest-analyst` identities do not exist): 403 for an agent on all four, `performance.team` for the per-agent routes and `reports.view` enough for the overview and the tag use, more than 92 days, a group outside the four and a bad market or line 400, no hash, number, call id or telephony user id in any answer, the groups adding up to the total, the previous period like for like (a running period against the same point, an ended one against the whole previous period), the threshold from the settings, a market and a line narrowing all four answers alike, people by name, counted tags per person, a tenant without telephony. Reads only; runs against mock or api data; the full run includes them | app in mock auth mode, `BASE`; for a local database `reports-fixture.sql` at `db/63` |
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
