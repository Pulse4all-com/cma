# 5.14 UX and UI review: findings

Examined: every page under `web/src/app`, every component under `web/src/components`, `copy.ts`, `nav.ts`, `globals.css`, `useKeyboardShortcuts.ts`, the 82 mock screenshots in `local-records/ux/before/`, and the running production build on 127.0.0.1:8080 with Playwright (Chrome 141) and axe-core from `web/node_modules`; scripts and raw outputs in `/var/tmp/5.14/` (`speed.mjs`, `nav.mjs`, `hydration.mjs`, `hydration2.mjs`, `axe.mjs`, `axe.json`, `contrast.mjs`).
How: code reading with file:line, then live measurement of the write paths, navigation, layout shift, focus and hydration; contrast computed from the tokens; mock data only, in-memory writes only (one status change and one clock-in for agent-two).
Time: about two hours of reading and measurement.
Most important: (1) client components format dates with `Intl` during render and Node 22's ICU 77 disagrees with Chrome 141's ICU 78 on en-GB weekday patterns, so Messages, Roster and Alert rules throw React #418 on every load for English users; (2) the rail numbers pages past 9 ("10"–"18") and the hook can never fire those keys; (3) a status change or clock-in drops keyboard focus to `<body>`, so S → arrows → Enter has to start over every time; (4) no feedback at all between a click and the page swap (140–370 ms), no `loading.tsx`/`error.tsx`/`not-found.tsx`; (5) the style guide's own badge pairs and focus ring fail WCAG contrast (axe: 56 nodes on 10 pages).
Nothing here touches time, pay, RLS, authentication or ingest; every fix is a web/ change. The full review with tables is `UX_REVIEW.draft.md` next to this file.

### UX-01: Hydration text mismatch (React #418) on Messages, Roster planner and Alert rules from client-side date formatting
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/components/Inbox.tsx:35,120`; `web/src/components/RosterPlanner.tsx:389,420` (via `web/src/lib/time.ts:78-86` `fmtDate` compact) and `RosterPlanner.tsx:357` (no `timeZone`); `web/src/components/configuration/AlertRulesConfig.tsx:94` via `web/src/components/configuration/SourcesList.tsx:157`
- Evidence: `/var/tmp/5.14/hydration.mjs` and `hydration2.mjs` compare the SSR HTML (scripts off) with the hydrated DOM. Observed: `/messages` SSR "Sat 17 Oct, 19:14" → DOM "Sat, 17 Oct, 19:14" (agent-two and manager, UTC and Europe/Amsterdam browsers, `pageerror` #418 each time); `/roster/planner` `thead th` SSR "Mon 12 Oct" → DOM "Mon, 12 Oct"; `/roster/planner?team=nl` (a published week) SSR "Published as version 1 on 17 Oct 2026, 16:56" → DOM "… 18:56" in a Europe/Amsterdam browser (the `timeZone`-less formatter), no diff in a UTC browser; `/configuration/alert-rules` SSR "Last alert Sat 17 Oct 18:31" → DOM "Last alert Sat, 17 Oct 18:31". Cause confirmed by formatting the same instant in both runtimes: Node 22.22 (ICU 77.1) `"Sat 17 Oct, 14:05"`, Chrome 141 `"Sat, 17 Oct, 14:05"`; `nl-NL` is identical in both. The lead's screenshot log shows the same #418 on exactly these three routes.
- Impact (in this system's context): on every load of the inbox (page 2 for everyone), the planner and the alert rules, React discards the server HTML and re-renders the client tree (slower first paint, a console error on every visit, the planner's day headers flip format after load). Prod runs Node 22 against users' Chrome 141+, so this is live for English-locale users; Dutch users are spared only by the pattern.
- Recommendation: build the weekday-day-month label from `formatToParts` so the pattern is the app's own, and route every client-side date through `lib/time.ts`; add the zone to the published-as label. Small diff:
```
--- a/web/src/lib/time.ts
+++ b/web/src/lib/time.ts
@@ export function fmtDate(key: DateKey, locale: Locale, style: "long" | "short" | "compact" = "long"): string {
   const d = toUtcDate(key);
-  return new Intl.DateTimeFormat(intlLocale[locale], {
-    timeZone: "UTC",
-    weekday: style === "short" ? undefined : "short",
-    day: "numeric",
-    month: style === "long" ? "long" : "short",
-    year: style === "long" ? "numeric" : undefined,
-  }).format(d);
+  // Assembled from parts: ICU 78 (Chrome 141) writes "Sat, 17 Oct" where ICU 77 (Node 22) writes
+  // "Sat 17 Oct", and a client component must render the same text as the server (React #418)
+  const parts = new Intl.DateTimeFormat(intlLocale[locale], {
+    timeZone: "UTC",
+    weekday: style === "short" ? undefined : "short",
+    day: "numeric",
+    month: style === "long" ? "long" : "short",
+    year: style === "long" ? "numeric" : undefined,
+  }).formatToParts(d);
+  const v = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
+  const date = style === "long" ? `${v("day")} ${v("month")} ${v("year")}` : `${v("day")} ${v("month")}`;
+  return style === "short" ? date : `${v("weekday")} ${date}`;
 }
```
  In `Inbox.tsx:35` replace `fmtWhen` with `${fmtDate(dateKeyInZone(instant, timeZone), locale, "compact")}, ${fmtTime(instant, timeZone, locale)}` (one definition with `SourcesList.fmtWhen`); in `RosterPlanner.tsx:357` use `fmtDateTime(header.publishedAt, viewerZone, locale)` (the prop already exists, unused). Add to `verify/layout.mjs`: fail on any `pageerror` whose message contains `#418`. Check the Dutch long form still reads "za 17 okt" / "17 oktober 2026" after the change.
- README check: new (the README says the Live board and Team hours pre-format on the server for this reason, but the rule is not stated for every client component).
- Disproof attempt: tried a UTC browser to rule out a time-zone cause: the weekday mismatch persists in UTC, so it is the ICU pattern, not the zone; the `timeZone`-less label mismatches only with a non-UTC browser, so both causes are real. Checked the other date-bearing client components (Welcome updates, Send table, invitations, Live board, Follow-up, Sources list): no diff, no error.

### UX-02: Page keys "10" to "18" are shown as keycaps but can never fire
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/lib/nav.ts:211,214` (`key: String(++n)`); `web/src/hooks/useKeyboardShortcuts.ts:352` (`if (typing || e.key.length !== 1) return`)
- Evidence: observed `data-shortcut` on the rail (`/var/tmp/5.14/nav.mjs`, `keys.*`): supervisor 1–15, manager 1–18 (Dashboard "10", Data quality "18"), admin 1–18, analyst 1–12; agent 1–5. `speed.mjs` crashed on `keyboard.press("10")` for the same reason a person cannot press it. The README (API, Shell and navigation) still says "a manager or admin nine" and the layout verifier checks only that the numbering has no gaps.
- Impact: every report page of the manager, supervisor, admin and analyst shows a keycap that does nothing; pressing "1" first navigates to Welcome. The keyboard-first promise (style guide 7.8, README) is broken exactly on the pages a manager opens all day, and the keycap misleads.
- Recommendation: number only the first nine visible pages; a later page gets `key: null` (no keycap, no `data-shortcut`, no `aria-keyshortcuts`): in `nav.ts` `visibleNav`, replace `String(++n)` with `(++n <= 9 ? String(n) : null)` in both places; the `Keycap` on a bare page (`Shell.tsx:298`) then needs the same `item.key ?` guard the grouped pages already have (`Shell.tsx:330`). Extend the layout verifier: no `data-shortcut` longer than one character. Alternative (PROPOSAL): group letters (R opens Reports and focuses its first page, digits inside the group), a README decision.
- README check: new; the README's "nine" dates from before B11/0008i/0008j/0008o/0008p added nine report pages.
- Disproof attempt: considered whether the hook could read two digits (it reads one `keydown`, no buffer) or whether the Reports group's `shortcut` already covered it (only Configuration has a letter). It stands.

### UX-03: A status change or clock-in drops keyboard focus to body; no optimistic state
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/components/WorkdayPanel.tsx:173-185,258` and `web/src/components/ClockInCard.tsx:24-54`
- Evidence: observed with Playwright as agent-two (`/var/tmp/5.14/speed.mjs`): S then Enter on "Training": all five status buttons `disabled` within 21 ms, `document.activeElement` is `BODY` at 21 ms and still `BODY` after the badge changed at 131 ms and after settle; Clock in: button disabled 176 ms with unchanged text, then `activeElement` `BODY`. Both writes are `fetch` then `router.refresh()`; the new state appears only after the full server re-render.
- Impact: an agent working by keyboard (the README's S, arrows, Enter) loses their place after every status change and must press S again; a screen reader user hears nothing (no live region announces the new status). The optimistic part is cosmetic at this server's speed (131 ms observed), but on a slow link the badge keeps the old status for the whole round trip with no pending words.
- Recommendation: (1) keep the focus: after the transition, focus the button of the new status (`aria-pressed`), e.g. in `changeStatus` remember `key` in a ref and in an effect on `workday.statusKey` focus `group.current?.querySelector('[aria-pressed="true"]')`; after Clock in, the page replaces the card: focus the status group (`[data-shortcut="s"]`) in `WorkdayPanel` on first mount when the previous page had the Clock in button (or simply `autoFocus` the current status button on mount); (2) disable only the clicked button, not all five, so focus is not dropped by the browser; (3) optimistic badge: set a local `pendingKey` and show its name and dot until the refresh lands, revert on `!res.ok` (the existing `statusFailed` alert covers the message); (4) a `role="status"` span that announces "Status: Training" after the change.
- README check: new (Status and clock paragraph describes the keyboard model; nothing settles the pending behaviour).
- Disproof attempt: checked whether the native `<dialog>` restores focus elsewhere (it does, observed for End workday and Correct a day), so the loss is specific to disabling the focused button and replacing the card.

### UX-04: Nothing happens on screen between a click and the page swap; no loading, error or not-found boundaries
- Severity: Medium   Confidence: High   Effort: M
- Component: `web/src/app/**` (no `loading.tsx`, `error.tsx`, `global-error.tsx`, `not-found.tsx`: `find` → 0); `web/src/components/Shell.tsx` rendered inside each of 23 pages instead of `app/layout.tsx`; rail links without `prefetch` (`Shell.tsx:284-299,317-331`)
- Evidence: observed (`/var/tmp/5.14/nav.mjs`): client swap 140–370 ms (first pass) and 112–253 ms (second pass) per rail click; during the swap the DOM has exactly two states (old page, new page): no `aria-busy`, no cursor change, `aria-current` flips only at the end; a 1 s hover on a rail link made 0 RSC requests. `GET /nope` → Next's default "404 · This page could not be found." in inline styles, English, no shell. The End workday server action (`WorkdayPanel.tsx:187-193`) has no catch: a throw has no boundary to land in (expected, not provoked). Mark read / acknowledge failures in `Inbox.tsx:58-63,69-74` are silent (`if (res.ok)` only; `messages.loadFailed` exists and is unused).
- Impact: the brief's "feedback within 100 ms" is missed on every navigation, and on a slow link the Workspace looks frozen for the whole round trip; a database hiccup shows an unbranded English error page to Spanish and Dutch agents with no next step; a mistyped address does the same.
- Recommendation: SAFE now: a small client `RailLink` wrapping `next/link` with `useLinkStatus()` (available in `next@16.3.8`) that sets `aria-busy` and dims the label while pending, `prefetch` on rail links; `app/error.tsx` and `app/not-found.tsx` rendering a calm card in the shell's palette with copy in both languages ("This page could not be loaded. Try again or go to Welcome" / "This page does not exist. Go to Welcome"), and a `try/catch` around `endWorkdayAction()` showing a new `myDay.endFailed`; a message on Inbox write failures. PROPOSAL: move `Shell` into a route layout (active page from the pathname, `wide` and `trail` through a slot) so Next streams the shell within one frame and a `loading.tsx` skeleton per route group can match the final layout (title, period bar, card).
- README check: new; the realtime/polling choice (Decision log 1747, 1848, Open decision 2097) is unrelated to navigation feedback.
- Disproof attempt: checked that Next's default prefetch would help without `loading.tsx` (it prefetches only static parts; all pages are dynamic per request, so nothing is prefetched: consistent with 0 requests observed) and measured a second pass to rule out cold caches (still 112–253 ms with no feedback).

### UX-05: The style guide's badge colours and focus ring fail WCAG AA contrast on every page that uses them
- Severity: Medium   Confidence: High   Effort: S (tokens) / decision with Mark
- Component: `web/src/components/primitives.tsx:119-125` (Badge tones), `web/src/app/globals.css:115-118` (focus ring), tokens from `docs/style/Pulse4all-Style.md` 2.3, 7.2, 7.5
- Evidence: computed (`/var/tmp/5.14/contrast.mjs`): success `#27AE6F` on `#E6F6EE` 2.55:1, warning `#C98A1B` on `#FBF1DC` 2.62:1, error `#B8433C` on `#F8E4E1` 4.40:1 (12 px text needs 4.5:1); `text-p4a-success` on white 2.85:1 (roster "Saved", "Link copied"); focus ring `#9ECFF5` on white 1.65:1, on Sand 1.62:1, on Background Blue 1.48:1 (WCAG 2.2 1.4.11: 3:1). Observed by axe-core (`/var/tmp/5.14/axe.json`): `color-contrast` serious, 56 nodes on 10 of 29 pages (People 11, Follow-up 12, Sources 10, Statuses 5, Absences 5, Markets 4, App links 3, Alert rules 3, Messages 2, Send 1), all badges.
- Impact: the chips a supervisor scans all day ("Needs a correction", "Not clocked out", "Active", "Urgent", "At risk", "Over time") are the least legible text on the screen, and the focus indicator the style guide mandates is barely visible on light surfaces, which weakens keyboard-first. The guide's own 7.8 says body text ≥ 4.5:1 and visible focus states.
- Recommendation: PROPOSAL (changes semantic tokens; guide section 14 says flag to Mark and log a D-series decision): darker text tones for the badges, same hue: success `#17784A` (4.91:1 on its surface), warning `#8A5D0F` (5.12:1) or `#9C6A12` (4.17:1, still short), error `#A83D36` (5.07:1); or Inkt text on the tinted surface with the colour as a dot (14.4:1). Focus ring: Denim `#3B6FB3` (5.1:1 on white) or Deep Blue, keeping the 2 px / offset 2 px. Add the new tones to the theme verifier's palette and the guide's 2.3 table.
- README check: new; the semantic colours are "proposed defaults" in the guide (2.3), not brand-book entries, so this is the project's call.
- Disproof attempt: checked whether the 12 px semibold badge text qualifies as "large text" (it does not: 18.66 px bold is the threshold) and whether axe flagged false positives from overlays (the urgent dialog was acknowledged before each run; the flagged nodes are plain badges).

### UX-06: Live board shows "Waiting 0 min" for callers missed hours ago outside office time
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/components/InboundLive.tsx:353-357` (`callbackWaiting` business seconds formatted as minutes); copy `live.missedWaiting`, hint `hints.missedWaiting`
- Evidence: `manager-1280-live_board.png`: five missed callers, missed at 05:02, 17:02, 17:27, 17:47, 18:22 on a Saturday, every "Waiting" cell "0 min" because waiting counts office time of the line's market and the office is closed; the hint explains it, the cell does not.
- Impact: the one figure that should rank the callbacks reads as "just missed" for all of them; a manager cannot tell the caller missed at 05:02 from the one missed at 18:22 without the "Missed at" column and the hint. On a daily-path screen this makes a figure read wrongly at a glance (the preamble's scale puts a misleading figure on a daily page at High; rated Medium because the hint and the Missed at column are right next to it).
- Recommendation: SAFE: when the business seconds are 0 and the market is closed now (the `callbackWaiting` result can carry `closed: true`, or compare office hours), render `live.missedClosed` ("Closed" / "Gesloten") in Muted with the elapsed clock time in its title; keep the figure for open hours. Copy in both languages; the figure's definition does not change.
- README check: new (addition 0008i describes "waiting in office time of the line's market"; nothing settles the display at 0).
- Disproof attempt: confirmed in `lib/live.ts` `callbackWaiting` that the `business` kind yields 0 outside hours rather than falling back to clock time (the `clock` kind is only for a line without a market), so the display is the only place to say "closed".

### UX-07: Labels rendered in ALL-CAPS by CSS on the toast and the urgent pop-up
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/components/MessageCenter.tsx:225` (`uppercase tracking-wide` on the toast kind) and `:246` ("URGENT MESSAGE")
- Evidence: every "before" screenshot of a manager page shows "URGENT MESSAGE" over the dialog title; the copy itself is "Urgent message" (`messages.urgentTitle`), so verify:copy passes.
- Impact: style guide rule 4 ("No ALL-CAPS, not in headings, labels, buttons or badges") is broken on the most visible element in the app; the copy verifier cannot catch a CSS transform.
- Recommendation: remove `uppercase tracking-wide` from both; a `text-caption font-semibold` label in Warning amber (pop-up) or Muted (toast) keeps the hierarchy. Extend the theme verifier: no element with computed `text-transform: uppercase` except two-letter codes (`TeamsConfig.tsx:105`).
- README check: new.
- Disproof attempt: checked whether the guide allows small caps for eyebrow labels (it does not; rule 4 is "across all channels").

### UX-08: Needs attention "days not clocked out" lands on the whole month, not on the rows to fix
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/lib/follow-up.ts:192` (`href: "/team/hours?range=month"`); `web/src/components/TeamHoursView.tsx` (filters: person only)
- Evidence: the Welcome line "1 day in the last 31 days was not clocked out" links to Team hours for the month; the table has no filter or ordering for `needsCorrection`/`isCapped` rows; with a real team (20 agents × 22 days) the one row to fix sits among 400.
- Impact: the cockpit handle exists but does not land on the signal; the manager scans for the warning chip by eye.
- Recommendation: SAFE: a `needs=correction` query that filters the rows to `needsCorrection || isCapped` (server side in `team/hours/page.tsx`, kept by `PeriodBar keep`), the Welcome link pointing at it, and a visible chip "Showing days to correct · Show all"; copy in both languages.
- README check: new.
- Disproof attempt: checked whether the rows are at least sorted with the chips first (they follow the data layer's order by date and person; no).

### UX-09: Dialogs without an accessible name; a labelled div without a role
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/components/PersonDialog.tsx:185`, `InviteDialog.tsx:143`, `configuration/shared.tsx:294` (FormDialog), `ConfirmDialog.tsx:397`, `MessageCenter.tsx:238` (no `aria-labelledby`; `DayEditor.tsx:197` has one); `web/src/components/LiveBoard.tsx:100` (`<div aria-label>`)
- Evidence: observed `personDialog.hasAriaLabel: {labelledby: null, label: null}` (`nav.mjs`); axe `aria-prohibited-attr` incomplete on `/live/board`.
- Impact: a screen reader announces "dialog" without saying which (Edit person, Invite, End your workday, Urgent message); the tiles group is unnamed.
- Recommendation: give each `<h2>` an id and the `<dialog>` `aria-labelledby`; `role="group"` on the tiles container. Add to `verify/layout.mjs`: every `dialog[open]` has an accessible name.
- README check: new.
- Disproof attempt: checked that native `<dialog>` does not derive a name from its first heading (it does not).

### UX-10: Line switch-off dialog cannot ask for the count of calls removed (CMA-020)
- Severity: Low   Confidence: High   Effort: M (a read column)
- Component: `web/src/components/configuration/SourceConfig.tsx:812-818`; `web/src/lib/data/types.ts:1367-1375` (`SourceLine` has no count); the delete in `db/54_uncounted_lines.sql:153-158`
- Evidence: `configSources.lineOffConfirm` says "switching a line off removes its stored calls" with the line's name only; the lines read returns no stored-calls count, so the dialog has nothing to show or to ask back.
- Impact: the irreversible confirmation states the consequence but not its size (the model the brief names is "asks for the count").
- Recommendation: PROPOSAL: add `storedCalls` to the lines read (a count of `cma.telephony_call` per `line_ref` of the connection, in the function behind `getSource`), show "Stop counting {name}? This removes {n} stored calls …" and, as CMA-020 asks, require typing the count (or the line's name) to enable the destructive button. A db change needs the 0008q pair and `docs/datamap/catalog.json` per CLAUDE.md.
- README check: already open (backlog CMA-020).
- Disproof attempt: searched the sources read for a count (`seenCalls` exists for missed reasons, not for lines).

### UX-11: Polish items (no finding of their own)
- Severity: Info   Confidence: High   Effort: S each
- Component / evidence: Team hours total "10h 48m" wraps (`TeamHoursView.tsx:221-222`, `manager-1280-team_hours.png`); Dashboard Intake tiles six across at 1280 with three-line hints (`ReportParts.tsx:389`, `manager-1280-reports_dashboard.png`); sent-messages title column one word per line (`messages/send/page.tsx:48-77`, `manager-1280-messages_send.png`); Absence types and Markets tables render header-only when empty (`AbsenceConfig.tsx:68`, `MarketsConfig.tsx:129`); the inbox badge mounting shifts the top bar by one badge width (CLS +0.0003 on every page, `speed.mjs`); the hook does not filter `e.repeat`; `roster.coverageIntro` could say who sets the targets ("an admin, on Configuration"); page primaries are 40 px where guide 7.2 says 48 (a derived dense-screen choice worth one line in the README).
- Recommendation: fold into the lead's fix PR where trivial.
- README check: new.

## Checked and found clean
- Tone of voice and copy rules: `npm run verify:copy` PASS (1728 keys, en and nl; no exclamation marks, no trailing periods on short titles, no all-caps words, no backend mechanics, every key in both languages).
- Layout shift: CLS 0.0003–0.0061 on 17 manager pages (`speed.mjs`), nothing moves when data arrives.
- Horizontal scroll at 1280: all 82 screenshot rows have `scrollWidth` equal to the viewport (`screenshots-before.log`); wide tables scroll inside their cards with `role="region"` and `tabIndex`.
- Keyboard hook ignores Ctrl/Alt/Meta (AltGr safe), typing in fields, scopes to an open dialog, prefers page controls over the rail (`useKeyboardShortcuts.ts:345-358`).
- Dialog focus return: End workday → E button, Correct a day → the row's Correct button, Edit person → Edit (observed); irreversible confirmations open on Cancel with the destructive secondary style (`ConfirmDialog.tsx:388-419`).
- Focus ring present and `:focus-visible` (observed `solid 2px rgb(158,207,245)`, offset 2 px); contrast is the only problem (UX-05).
- Double submits guarded on every write button; refused actions explain the rule (clock-in window with the database's time, frozen flags, past roster day, own day, invite ceiling, kind conflict).
- Colours by meaning: status colours from flags, deltas as muted text, no donuts, no filled red tiles, labels next to every mark (`DashboardCharts.tsx`, `CallsParts.tsx`, `FormsParts.tsx`, `FollowUpTables.tsx`); theme verifier guards the palette.
- Dates and numbers in the person's locale through `lib/time.ts` (`en-GB`/`nl-NL`), the roster week range via `formatRange` (CMA-061 observed), times in the day's own zone with the zone's short name when it differs.
- Hints toggle (CMA-004) observed: `?` hides every `kbd`, writes `cma-hints=hidden`, `aria-pressed` true, keys keep working; breadcrumbs and folding rail (CMA-063) on every page.
- Expected-differences notes for figures a manager reconciles with Aircall or HubSpot: talk time without ringing (Calls intro and hints), service level definition with the seconds (Inbound `slNote`), medians do not add up (Speed to lead), "No history to compare yet" on Calls and Forms, "counted" lines/forms/pipelines named in every hint.
- `prefers-reduced-motion` honoured (`globals.css:120-127`); `DesktopOnly` pure CSS with print variants.
- Every visible control has an accessible name (axe: no `label`, `button-name`, `link-name` or `select-name` violation on 29 pages; inputs sit inside `<label>` wrappers).
- Empty states exist in both languages for every list but the two configuration tables named in UX-11; "No telephony connected"/"No shop connected"/"No forms received" shown in words, never 0.
- The Live board poll keeps client state (filter and open hint survive a refresh, observed) and ticks the clock locally; polling is settled (Decision log 1747, 1848, 1989; Open decision 2097).

## Not checked / could not check
- Real latency on a slow link or the prod image (sandbox only; the lead's p95 ≤ 77 ms TTFB taken as given).
- Screen-reader output (no AT in the sandbox; names and roles judged from the DOM and axe).
- The Dutch copy's wording quality (parity and rules verified; readability not judged by a native reader).
- Touch and 1600+ px behaviour beyond the screenshots (desktop-only by decision).
- The print view's output on paper (not printed).
- `verify:theme`, `verify:layout`, `verify:hints` themselves (they need the server and are Martin's to run; their headers were read to avoid duplicating what they prove).

## Commands run
- `npm run verify:copy` (web/): PASS, 1728 keys.
- `node /var/tmp/5.14/contrast.mjs`: contrast table (see UX-05).
- `node /var/tmp/5.14/speed.mjs`: clock-in and status-change samples, focus, dialog, CLS per page, Live board poll; crashed at the navigation step on key "10" (UX-02); rerun as `nav.mjs`.
- `node /var/tmp/5.14/nav.mjs`: keycaps per subject, click navigation 2 passes, prefetch on hover (0 requests), feedback during swap (none), focus ring, Team hours and People dialog focus return.
- `node /var/tmp/5.14/hydration.mjs`, `hydration2.mjs`: SSR versus hydrated DOM diffs on 9 pages in UTC and Europe/Amsterdam, browser ICU output, hints toggle.
- `node /var/tmp/5.14/axe.mjs`: axe-core WCAG 2.x A/AA on 29 pages across five subjects → `/var/tmp/5.14/axe.json`.
- `curl` of `/`, `/day`, `/nope`, `/live/board` HTML with the mock header; `ps`/`curl -I` to confirm the 8080 server is the production build.
- `git diff web/src/lib/nav.ts` after the lead's concurrent edit (adds `config-health`, unrelated to UX-02).
- Mock writes made: one clock-in and one status change (Available → Training) for `agent-two`; urgent fixture messages acknowledged for agent-two, manager, supervisor, admin; all in memory.
