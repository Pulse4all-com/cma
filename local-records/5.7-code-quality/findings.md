# 5.7 Code quality and maintainability: findings

**Summary.** Examined `web/src` (229 files, 31,546 lines), `web/verify` (6,116 lines), `web/jobs`, `ingest/src` (6,573 lines), `ingest/jobs` (51 lines), `ingest/verify` (4,718 lines) and `db/` at commit `35ea3e0` (17 October 2026), by static grep, `npm run lint`/`typecheck` in web, `npm run lint`/`npm test` in ingest, knip (`knip@latest` with TypeScript 5.9.3 pinned, read-only, after knip 5.50.5 failed on a TS API mismatch), a copy-key script and a draft boundaries verifier run against the tree; about two hours.
The codebase is in good shape: TypeScript strict with `noUncheckedIndexedAccess`, zero `any`, zero `@ts-ignore`, one justified `eslint-disable`, lint and typecheck clean, ingest's 14 pure verifiers all pass, the boundary "screens → `@/lib/data`, identity → `@/lib/auth/identity`" holds (171 and 9 imports; two exceptions found).
Most important: (1) copy placeholders are filled by 167 inline `String.replace("{x}", value)` calls in 40 files with no shared helper; string-pattern `replace` expands `$` patterns, so a connection, form or person name holding `$'`, `$&` or `$$` renders wrongly (proven in Node); (2) the test posture has three gaps that matter for time and pay data: no test of the concurrent double clock-in branch (`db/46_workday_window.sql:275`), `proxy.ts` tested only end to end against a running server, and mock/postgres parity proven only by TypeScript; (3) 20 unused exports plus 5 unused exported types in web, 29 in ingest, and 10 copy keys referenced nowhere.
Counts are observed unless marked otherwise.

## Counts table (web/src unless stated)

| Measure | Count | Note |
|---|---|---|
| `any` in a type position | 0 | the one `\bany\b` hit is a comment (`lib/sources.ts:29`) |
| `as any` | 0 | two hits are prose in comments |
| `as unknown as` | 2 | both `globalThis` slots: `lib/data/mock.ts:689`, `lib/db/client.ts:108` |
| `!` non-null assertions (heuristic) | 59 | 23 in `lib/data/mock.ts` fixtures; expected under `noUncheckedIndexedAccess` |
| `@ts-ignore` / `@ts-expect-error` / `@ts-nocheck` | 0 | |
| `eslint-disable` | 1 | `components/DayEditor.tsx:117`, mount-only effect, justified |
| `console.log` | 0 | 8 `console.*` in all: 5 `error`, 3 `warn` |
| `.replace("{x}", …)` copy fills | 167 in 40 files | 6 `replaceAll`; one regex helper (`lib/invitations.ts:152`) |
| files > 600 lines in web/src | 6 | `copy.ts` 3655, `data/mock.ts` 3100, `data/types.ts` 2051, `data/postgres.ts` 1995, `reports.ts` 1473, `configuration/SourceConfig.tsx` 821 |
| files > 600 lines in ingest/src | 0 | largest `core/store.mjs` 511 |
| files > 600 lines in web/verify | 3 | `api.mjs` 1616, `layout.mjs` 1095, `reports.mjs` 672 |
| knip unused exports / types (web) | 20 / 5 | all grep-confirmed, see CQ-03 |
| knip unused exports / files (ingest) | 29 / 1 | `tools/replay.mjs` is a documented tool, not dead |
| unused copy keys | 10 | of 1728; see CQ-02 |
| web lint / typecheck | 0 errors, 1 warning / clean | warning: `verify/follow-up.mjs:43` unused `uid` |
| ingest lint / `npm test` | clean / all 14 pure verifiers pass | |

Severity counts: Critical 0, High 0, Medium 2, Low 7, Info 3.

---

### CQ-01: Copy placeholders are filled by 167 inline `String.replace` calls; `$` in a value corrupts the text
- Severity: Medium   Confidence: High   Effort: M
- Component: `web/src/lib/copy.ts` consumers (40 files under `web/src/app` and `web/src/components`)
- Evidence:
  - Observed: `grep -rnoE '\.replace\("\{[a-zA-Z]+\}"' web/src` → 167 sites in 40 files; `replaceAll` 6 sites; the only safe helper is `fill()` in `web/src/lib/invitations.ts:152` (`template.replace(/\{(\w+)\}/g, (m, k) => …)`), used for the invitation mail only; `fillHint` (`web/src/lib/reports.ts:1169`) uses `replaceAll` with string patterns.
  - Observed, user-sourced values passing through string-pattern `replace`: `components/configuration/SourceConfig.tsx:809` (`t.switchOffConfirm.replace("{name}", conn.name)`), `:817` (a line's name), `:713` (a form category name), `components/configuration/TeamsConfig.tsx:252` (a team name), `components/FormsParts.tsx:86` (a HubSpot form's name), `components/CallsPerAgentTable.tsx:125` (a person's name), `components/InvitationsSection.tsx:100,103` (`createdByName`, `acceptedName`), `components/Shell.tsx:201` and `components/PreviewControls.tsx:62` (a role name), `app/roster/planner/print/page.tsx:63` (`publishedByName`).
  - Observed in Node 22: `"Switch off {name}?".replace("{name}", "Shop $' West")` → `"Switch off Shop ? West?"`; `… "Save $$ now"` → `"Switch off Save $ now?"`; `replaceAll("{name}", "A$&B")` → `"A{name}B"`. The regex-with-function form returns the value verbatim.
  - Observed: string-pattern `replace` fills only the first occurrence; the two copy strings that use one placeholder twice (`copy.ts:1080` `{version}`, `:1794` `{inviter}`) are filled with `replaceAll` (`app/roster/planner/print/page.tsx:67`) and the regex `fill` respectively, so that is handled today by discipline, not by construction.
- Impact (in this system's context): a connection, team, form, role or person name containing `$'`, `` $` ``, `$&` or `$$` renders a wrong confirmation, banner or label. Form names come from HubSpot and connection names from the admin; "$" is plausible in a marketing form name ("Save $$ today"). No HTML sink exists (`dangerouslySetInnerHTML`/`innerHTML`: 0 hits), so this is wrong text, not injection. The maintainability cost is the larger one: 167 call sites each re-implementing the fill, so a rule change (escaping, a missing value shown as a dash, plural forms) touches 40 files.
- Recommendation: one helper in `copy.ts` and a verifier rule.
  ```diff
  --- a/web/src/lib/copy.ts
  +++ b/web/src/lib/copy.ts
  @@ export function t(locale: Locale): Copy {
  +/**
  + * A copy string with its {placeholders} filled: every occurrence, the value verbatim ($ patterns
  + * never expand), an unknown placeholder left as it is so the copy verifier can see it.
  + */
  +export function fill(text: string, values: Record<string, string | number>): string {
  +  return text.replace(/\{(\w+)\}/g, (m, k: string) => (k in values ? String(values[k]) : m));
  +}
  ```
  Then replace `x.replace("{a}", v).replace("{b}", w)` with `fill(x, { a: v, b: w })` mechanically (a codemod over the 167 sites; `reports.ts` `fillHint` and `invitations.ts` `fill` fold into it). Add to `verify/copy.mjs` a rule that no file under `src/` calls `.replace("{` or `.replaceAll("{` (grep over the tree, as `invitations.mjs` already reads routes as text), so the pattern cannot return.
- README check: new (the Decision log has no entry on copy interpolation; 2019 "Copy language for Newco agents" is about locales, not fills).
- Disproof attempt: looked for a central helper (`grep -rnE 'export function (fill|format|interpolate)'`): only `fillHint` and invitations' `fill`. Checked whether values are sanitised upstream (the database limits names to 100 characters, no character class: `SourceConfig.tsx:96` checks length only). Checked for a regex form at the call sites: none of the 167. The `$` expansion is specified ECMAScript behaviour (GetSubstitution), confirmed by running it.

### CQ-02: The copy verifier proves neither placeholder parity nor key use; 10 keys are dead
- Severity: Low   Confidence: High   Effort: S
- Component: `web/verify/copy.mjs`, `web/src/lib/copy.ts`
- Evidence:
  - Observed: `copy.mjs` (65 lines) checks: every key in every language, no empty string, no exclamation mark, no trailing period on five words or fewer, no all-caps word, no backend word. It does not compare the `{placeholders}` of `en` and `nl` and does not look at the code.
  - Observed with `/var/tmp/5.7/copy-check.mjs`: 1728 keys, placeholder mismatches between en and nl today: 0 (so the gap is unproven protection, not a present bug).
  - Observed, keys whose leaf name appears nowhere in `web/src`, `web/verify` or `tools/` outside `copy.ts` (grep, dynamic access considered): `welcome.todo`, `welcome.notClockedOutOne`, `welcome.notClockedOutNone`, `welcome.openTeamHours`, `intakeRow.openReport`, `hints.formsDay`, `hints.formsWeek`, `team.holdsNot`, `configSources.responseTimeProblem`, `messages.colDelivered` (10, each in both languages). 41 other candidates are dynamic (`dataQuality.check_*`, `configSources.kind_*`, `mode_*`, `account.allow.*`) and are in use.
- Impact: a translator's slip (an `{n}` dropped from the Dutch string) would pass the verifier and ship a literal count missing from the sentence; dead keys cost translation effort and mislead the README's key counts (1728 includes them).
- Recommendation: extend `check()` and remove the ten keys.
  ```diff
  --- a/web/verify/copy.mjs
  +++ b/web/verify/copy.mjs
  @@ export function check(languages) {
     const allKeys = new Set(Object.values(flat).flatMap((f) => Object.keys(f)));
  +  const placeholders = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
  +  const langs = Object.keys(flat);
  +  for (const key of allKeys) {
  +    const shapes = new Set(langs.filter((l) => key in flat[l]).map((l) => placeholders(flat[l][key])));
  +    if (shapes.size > 1) problems.push(`${key}: placeholders differ between languages (${[...shapes].join(" | ")})`);
  +  }
  ```
  and in the provoke block `languages.nl.welcome.morning = "Goedemorgen";` (drops `{name}`). An unused-key check belongs in the same file (read `src/**/*.ts(x)` once, flag a leaf name that occurs nowhere, with an allowlist for the dynamic families named above).
- README check: new.
- Disproof attempt: for each of the ten keys grepped the leaf name and the parent object across `web/src`, `web/verify`, `tools` with word boundaries and as a template-literal fragment (`notClockedOut` alone is used at `app/team/hours/page.tsx:50`; the `One`/`None` variants are not). Checked that `verify/preview.mjs` reading `nav.ts` does not reference copy keys.

### CQ-03: Dead exports: 20 symbols and 5 types in web, 29 in ingest
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/**`, `ingest/src/**`
- Evidence (observed, `npx -p typescript@5.9.3 -p knip@latest knip --reporter compact`, cross-checked by grep over `web/src`, `web/verify`, `web/jobs`, `tools`: each symbol occurs in its defining file only):
  - web: `components/CallsParts.tsx: callsGroupLabel`; `components/FollowUpTables.tsx: slaBadge, dueBadge`; `components/LiveRefresh.tsx: REFRESH_MS`; `components/ShellPrefs.tsx: RAIL_CHANGED_EVENT`; `components/configuration/shared.tsx: refusalMessage`; `lib/auth/iap.ts: IAP_ISSUER, IAP_JWKS_URL, IAP_GOOGLE_SUB_PREFIX` (used inside the file; `config.ts:27` reads the env var of the same name); `lib/auth/identity.ts: MOCK_PROVIDER`; `lib/auth/preview.ts: PREVIEW_PERMISSION`; `lib/corrections.ts: offsetMinutesAt, fmtOffset, diff`; `lib/csv.ts: DEFAULT_EXPORT_SETTINGS`; `lib/data/mock.ts: MOCK_INVITE_TOKENS`; `lib/db/client.ts: CMA_SQLSTATE, translateDbError, ping`; `lib/follow-up.ts: SLA_STATES, DUE_STATES, leadNeedsAttention, ticketNeedsAttention, taskNeedsAttention`; `lib/invitations.ts: INVITATION_SETTING_KEYS`; `lib/logout.ts: LOGOUT_TARGETS`; `lib/messages.ts: INBOX_LIMIT_MAX, IDS_MAX`; `lib/nav.ts: navEntries`; `lib/reports.ts: round1, INTAKE_FIELDS, intakeVolume, FIRST_CHECKS, OUTBOX_PENDING_CHECK, UNKNOWN_REASON, reasonColours, timeInZone, TOP_TAGS, PER_AGENT_BARS`; `lib/sources.ts: SOURCE_KINDS, RECORD_URL_PREFIX, FORM_CATEGORY_CODE`; `lib/team.ts: DIMENSIONS`. Types: `corrections.ts: ResolvedRow`; `csv.ts: Separator, DecimalMark, DurationFormat`; `data/types.ts`: 14 named types; `follow-up.ts: AttentionKey`; `nav.ts: NavItem, NavPage, NavGroupEntry, NavEntry`.
  - ingest: 29 exports (full list in `/var/tmp/5.7/ingest-knip.txt`), mostly stream-name constants and `reset*` test hooks, e.g. `core/log.mjs: log` (callers import `info/warn/error`), `core/connection.mjs: KEY`, `adapters/hubspot/map.mjs: mapEvent`, `adapters/shopify/map.mjs: phoneHashOf`. `tools/replay.mjs` is reported as an unused file; it is a documented operator tool (README, Code; `docs/ingest/README.md`), not dead.
  - Observed: knip 5.50.5 via plain `npx` fails (`ts.getDefaultLibFilePath is not a function`); it works with the project's TypeScript version on the `npx` path.
- Impact: dead exports hide which functions are the real seams and make a refactor look riskier than it is; the `lib/data/types.ts` types suggest interface surface nobody consumes.
- Recommendation: drop the `export` keyword where the symbol is file-local (most of the list); delete the five web functions nobody calls (`callsGroupLabel`, `slaBadge`, `dueBadge`, `refusalMessage`, `diff`) after confirming no verifier reads them as text. Do not add knip as a dependency: the clean option in this repository is a `knip.json` kept next to `package.json` and the one-line `npx -p typescript@5.9.3 -p knip@latest knip` in `web/verify/README.md` as an occasional check, not a verifier (it needs the network).
- README check: new.
- Disproof attempt: for every web symbol, grep with `-w` across `web/src web/verify web/jobs tools`; four name collisions (`IAP_JWKS_URL`, `DIMENSIONS`, `ping`, `diff`) inspected line by line: the hits are other symbols of the same name (`app/account/page.tsx:7`, `lib/api/configuration.ts:69`, `components/MessageCenter.tsx`), not imports.

### CQ-04: Duplicated helpers inside web; cross-service duplication is deliberate and should stay so
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/lib/time.ts`, `web/src/components/RosterPlanner.tsx`, `web/src/lib/team.ts`, `web/src/app/account/page.tsx`, `web/src/lib/api/configuration.ts`, `web/jobs/close-forgotten-workdays.mjs`, `ingest/src/core/db.mjs`
- Evidence:
  - Observed, inside web: the `Intl.DateTimeFormat("en-CA", …)` date-key idiom is implemented in `lib/time.ts:15` (`dateKeyInZone`) and again verbatim in `components/RosterPlanner.tsx:81` (`todayOf`); `lib/corrections.ts:45` has a legitimately different formatter (hour and minute too). `DIMENSIONS = ["language", "work_type", "channel"]` is defined three times identically: `lib/team.ts:11` (exported, unused elsewhere), `app/account/page.tsx:7`, `lib/api/configuration.ts:69`.
  - Observed, across services: the database client exists three times by design: `web/src/lib/db/client.ts`, `web/jobs/close-forgotten-workdays.mjs:30-53` (pool opening, `required()`, the date type parser, the `set_config` triple) and `ingest/src/core/db.mjs` (header: "exactly as the web app's src/lib/db/client.ts"). They have drifted in one behaviour: the web client logs an idle-client error (`client.ts:124,146`), ingest swallows it (`db.mjs`: `pool.on("error", () => undefined)`), the scheduler job registers no handler at all (an idle-client error there would be an unhandled `error` event, exit code 1 after the tenant loop or a crash before `pool.end()`; estimated, not observed).
  - Observed: hashing (`createHmac`, `libphonenumber-js`) exists in ingest only (`ingest/src/core/hash.mjs`); web never handles a phone number (`grep createHmac|libphonenumber web/src` → 0; the one `createHash` is the mock's invite-token hash, `mock.ts:1667`). Time-zone and business-day logic lives in SQL (`cma.business_*`, 30 functions) and `web/src/lib/time.ts`; ingest does none (`grep timeZone|Intl ingest/src` → one comment). Date formatting is Intl in web only.
- Impact: the intra-web copies are the kind that diverge silently (a `todayOf` bug fixed in `time.ts` would survive in the planner). The cross-service copy is the right call: two deployables with their own `package.json`, one in TypeScript bundled by Next, one in plain Node; a shared package would need a workspace and a build step for the `.mjs` consumers and would couple two release cadences for 50 lines.
- Recommendation: `RosterPlanner.tsx:81` → `import { dateKeyInZone } from "@/lib/time"` and `dateKeyInZone(new Date(), zone)`; `account/page.tsx:7` and `api/configuration.ts:69` → import `DIMENSIONS` from `@/lib/team`. Keep the three database clients separate but give the scheduler job the same idle-error line as the services (`pool.on("error", (err) => console.error("[cma-db] idle client error", err.message))` after each `new pg.Pool`), and add one sentence to `ingest/src/core/db.mjs`'s header saying it deliberately mirrors `client.ts` and names what may differ.
- README check: settled in part (Decision log 9 October 2026 night build: the job is plain JavaScript on `pg` so it needs no build step; README Code paragraph). The intra-web duplicates are new.
- Disproof attempt: checked that `corrections.ts`'s formatter is not the same function (it is not: it formats hour and minute). Checked whether `RosterPlanner.tsx` is a client component that cannot import `time.ts` (`time.ts` has no runtime imports; `nav.ts`'s header documents that client modules may import such libs).

### CQ-05: Two screens import the database error class from `@/lib/db/client`; the mock loads the database module; `period.ts` breaks the pure-library import convention
- Severity: Low   Confidence: High   Effort: S (error move), S (verifier)
- Component: `web/src/app/configuration/sources/[id]/page.tsx:5`, `web/src/app/invite/accept/route.ts:3`, `web/src/lib/data/mock.ts:7`, `web/src/lib/period.ts:6`
- Evidence (observed with the draft verifier below, run against `web/src`; the same by grep):
  - R1: `app/configuration/sources/[id]/page.tsx:5` and `app/invite/accept/route.ts:3` import `CmaDbError` from `@/lib/db/client` (for `instanceof` and `sqlState`, lines 29 and 37). `db/client.ts` imports `pg`, the Cloud SQL connector and `server-only`; `CmaDbError` is not re-exported by `@/lib/data` (grep: 0).
  - R5: `lib/data/mock.ts:7` imports `CmaDbError` from `@/lib/db/client` to mimic refusals (122 throws), so the mock bundle depends on the database module.
  - R3: `lib/period.ts:6` is the only pure library with a runtime alias import (`from "@/lib/time"`); the other pure libraries import each other as `"./name.ts"` (Decision log 7 October 2026, index 1750: `allowImportingTsExtensions` so pure modules run under Node's type stripping). No verifier imports `period.ts` or `nav.ts` (`grep -l 'src/lib/(nav|period)\.ts' web/verify/*.mjs` → `preview.mjs` reads `nav.ts` as text only).
  - All other rules hold: 171 `from "@/lib/data"` imports and 0 of `@/lib/data/postgres|mock`; identity 9 imports of `@/lib/auth/identity`, 2 of the pure `@/lib/auth/preview` (the preview cookie's constants, in two routes), 0 of `@/lib/auth/iap` outside `proxy.ts`; 17 pure libraries with no runtime import outside the set; `lib/api/{calls,forms,configuration,roster}.ts` import only `respond`, `server-only`, `@/lib/reports`, `@/lib/sources` and types.
- Impact: the README rule "screens import data only through `src/lib/data`" is almost true; the two exceptions exist because the data layer's error type lives in the database module. Moving it is a 15-minute change that also lets the mock stop importing `pg`'s module. `period.ts` would fail under a pure verifier the day one is written, with a misleading "cannot find module" error. (5.1 covers the security angle of the same boundary; this is the maintainability one.)
- Recommendation:
  1. Move `CmaSqlState`, `CMA_SQLSTATE` and `CmaDbError` to a new `web/src/lib/data/errors.ts` (no imports), `export * from "./errors"` in `lib/data/index.ts`, and `import { CmaDbError, CMA_SQLSTATE, type CmaSqlState } from "@/lib/data/errors"` in `db/client.ts`, `api/respond.ts`, `mock.ts`, the page and the route.
  2. `period.ts:6` → `from "./time.ts"`.
  3. Add the verifier below as `web/verify/boundaries.mjs` and `"verify:boundaries": "node verify/boundaries.mjs"` to `package.json` (pure, no flags needed). On today's tree it reports exactly the four lines above; with `--provoke` it adds synthetic files that break R1, R2, R3 and R4 and fails.
  ```diff
  --- /dev/null
  +++ b/web/verify/boundaries.mjs
  @@ -0,0 +1,80 @@
  +/**
  + * Verifier: module boundaries of web/src (README, Code: screens import data only through @/lib/data and
  + * identity only through @/lib/auth/identity; the pure libraries have no runtime imports), without a
  + * browser, a server or a database.
  + *
  + *   node verify/boundaries.mjs             every rule must hold, exit 0
  + *   node verify/boundaries.mjs --provoke   adds files that break every rule: must FAIL, exit 1
  + *
  + * Rules (import statements only; type-only imports ignored):
  + *   R1 src/app/** and src/components/** never import @/lib/data/postgres, @/lib/data/mock, @/lib/db/*, pg
  + *      or server-only: data comes from "@/lib/data" alone.
  + *   R2 src/app/** and src/components/** never import @/lib/auth/iap: identity comes from
  + *      "@/lib/auth/identity" (and the pure "@/lib/auth/preview" for the cookie's constants).
  + *   R3 the pure libraries import nothing at runtime outside their own set, and another pure library only as
  + *      "./name.ts" (Decision log, 7 October 2026: Node's type stripping resolves no "@/lib" alias).
  + *   R4 src/lib/api/*.ts other than respond.ts import only respond, server-only, "@/lib/reports",
  + *      "@/lib/sources" and types: they validate, they do not read.
  + *   R5 src/lib/data/mock.ts imports nothing from @/lib/db/*: the mock must not load the database driver.
  + */
  +import { readdirSync, readFileSync, statSync } from "node:fs";
  +import { join, relative } from "node:path";
  +
  +const root = new URL("../src/", import.meta.url).pathname;
  +const PURE = ["csv", "dashboard", "team", "roster", "live", "reports", "messages", "configuration", "follow-up",
  +  "invitations", "sources", "period", "time", "nav", "alertRules", "corrections", "logout", "origin"];
  +
  +function walk(dir, out = []) {
  +  for (const name of readdirSync(dir)) {
  +    const p = join(dir, name);
  +    if (statSync(p).isDirectory()) walk(p, out);
  +    else if (/\.(ts|tsx)$/.test(name)) out.push(p);
  +  }
  +  return out;
  +}
  +
  +/** Runtime imports of a source as [{ from, line }]; `import type` and `import { type A }` left out */
  +export function runtimeImports(source) {
  +  const out = [];
  +  source.split("\n").forEach((text, i) => {
  +    const m = text.match(/^import\s+(?!type\s)(?:[^"']*?\s+from\s+)?["']([^"']+)["']/);
  +    if (!m) return;
  +    const names = text.match(/^import\s+\{([^}]*)\}/)?.[1];
  +    if (names !== undefined && names.split(",").every((n) => /^\s*type\s/.test(n))) return;
  +    out.push({ from: m[1], line: i + 1 });
  +  });
  +  return out;
  +}
  +
  +export function check(files) {
  +  const problems = [];
  +  for (const [path, source] of Object.entries(files)) {
  +    const screen = /^(app|components)\//.test(path);
  +    const pureName = path.match(/^lib\/([A-Za-z-]+)\.ts$/)?.[1];
  +    const isPure = pureName !== undefined && PURE.includes(pureName);
  +    const isApi = /^lib\/api\/[A-Za-z-]+\.ts$/.test(path) && path !== "lib/api/respond.ts";
  +    for (const { from, line } of runtimeImports(source)) {
  +      const at = `${path}:${line}`;
  +      if (screen && /^(@\/lib\/data\/(postgres|mock)|@\/lib\/db(\/|$)|pg$|server-only$)/.test(from)) problems.push(`R1 ${at}: imports ${from}`);
  +      if (screen && from === "@/lib/auth/iap") problems.push(`R2 ${at}: imports ${from}`);
  +      if (isPure) {
  +        const rel = from.match(/^\.\/([A-Za-z-]+)\.ts$/)?.[1];
  +        if (rel === undefined || !PURE.includes(rel)) problems.push(`R3 ${at}: runtime import ${from}`);
  +      }
  +      if (isApi && !/^(\.\/respond|@\/lib\/api\/respond|server-only|@\/lib\/reports|@\/lib\/sources)$/.test(from)) problems.push(`R4 ${at}: imports ${from}`);
  +      if (path === "lib/data/mock.ts" && /^@\/lib\/db(\/|$)/.test(from)) problems.push(`R5 ${at}: imports ${from}`);
  +    }
  +  }
  +  return problems;
  +}
  +
  +const files = Object.fromEntries(walk(root).map((p) => [relative(root, p), readFileSync(p, "utf8")]));
  +if (process.argv.includes("--provoke")) {
  +  files["app/x/page.tsx"] = 'import { postgresData } from "@/lib/data/postgres";\nimport { verifyIapJwt } from "@/lib/auth/iap";\n';
  +  files["lib/csv.ts"] = 'import { NextResponse } from "next/server";\n' + files["lib/csv.ts"];
  +  files["lib/api/x.ts"] = 'import { data } from "@/lib/data";\n';
  +}
  +const problems = check(files);
  +for (const p of problems) console.log("  " + p);
  +console.log(problems.length === 0 ? `boundaries: PASS (${Object.keys(files).length} files)` : `boundaries: FAIL (${problems.length} problems)`);
  +process.exit(problems.length === 0 ? 0 : 1);
  ```
  The scratch copy that produced the numbers above is `/var/tmp/5.7/boundaries.mjs` (it still lists `respond.ts` under R4; the diff excludes it, since `respond.ts` is the route helper that legitimately knows identity and the database).
- README check: the boundary itself is settled (README Code paragraph: "screens import data only through `src/lib/data` and identity only through `src/lib/auth/identity`"); the `.ts`-extension convention is settled (Decision log 7 October 2026, index 1750). The verifier is new.
- Disproof attempt: checked whether `CmaDbError` is meant to be part of the data contract (`types.ts` and `index.ts` never mention it, so screens have no sanctioned way to catch it). Checked whether `period.ts` is reached by any verifier (none) and whether the alias import matters at runtime for Next (it does not; it matters only for the type-stripping verifiers). Ran the draft on the real tree and with `--provoke`.

### CQ-06: Log prefixes: five in use in web, one line unprefixed, and the convention lives in code only
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/proxy.ts:58`, `web/src/app/invite/accept/route.ts:37`, `web/src/lib/auth/identity.ts:138`, README
- Evidence:
  - Observed, all eight `console.*` in `web/src`: `[cma-invite]` (invite route, `error`, a SQLSTATE only), `iap: token rejected: …` (`proxy.ts:58`, `warn`, jose error name and code; no prefix in brackets), `[cma-auth] preview ignored` (`identity.ts:138`, `warn`), `[cma-api]` twice (`respond.ts:63,66`: SQLSTATE and detail for 5xx; "unexpected" with the error message), `[cma-data] identity (provider) matches N tenants` (`postgres.ts:796`, `warn`, a count), `[cma-db] idle client error` twice (`client.ts:124,146`). None logs an email, a name, a token or an id of a person (checked each argument).
  - Observed: README has no occurrence of `cma-data`, `cma-db`, `cma-api`, `cma-auth` or `cma-invite` (grep 0 each); `docs/RUNBOOK.md` neither. The audit brief's premise that README names the prefixes does not hold.
  - Observed, ingest: one logger (`src/core/log.mjs`, JSON lines with `severity`), 54 calls (`info` 14, `warn` 31, `error` 9) in 14 files, 0 `console.*`, 0 raw `process.stdout` writes outside the logger; fields are consistently `connection`, `code`, `adapter`, counts and `ms`; the `error` field (`jobs/poll-email.mjs:37`) carries a code from `codeOf()`, never a message. Message naming mixes "job: detail" (10 single-token or colon style) and prose (41), e.g. `"sweep: outbox not checked"` beside `"read-back left to the sweeper"`; harmless, but a Logs Explorer filter on a job name works only for the colon style.
- Impact: Cloud Logging filters on the bracket prefix miss the IAP rejection line, the one line an operator looks for first during a sign-in problem. A convention nobody wrote down is one a future PR will not follow.
- Recommendation: `proxy.ts:58` → `` console.warn(`[cma-auth] iap: token rejected: …`) `` (keep the rest). Add one sentence to README (API section or Observability) naming the five prefixes and when each is used; keep ingest's "job: detail" shape for every job message.
- README check: new (no Decision log or Open decisions entry on log prefixes).
- Disproof attempt: searched README with and without brackets, with backticks, and `docs/` for the prefixes. Re-read each of the eight lines for a personal value (none: codes, counts, error names).

### CQ-07: Three header comments contradict the code they head
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/lib/data/types.ts:1-10`, `web/src/lib/data/postgres.ts:35`, `web/src/lib/reports.ts:6`
- Evidence (observed; 30 claims checked across the ten largest web files, 27 hold):
  - `types.ts:4-6`: "The mock implementation serves this increment; the API implementation (Postgres as cma_app, after migration 0002) replaces it without touching a component." `postgres.ts` has implemented it since 6 October 2026 (`postgresData: CmaData`, 110 methods); the header describes a past state.
  - `postgres.ts:35`: "Errors surface as CmaDbError with the function's SQLSTATE (CMA01 to CMA05)". `client.ts:40` defines CMA01 to CMA06 and `db/*.sql` raises CMA06 239 times (`grep -rhoE "CMA0[0-9]" db/*.sql`); CMA06 (not permitted) is the code every configuration function uses.
  - `reports.ts:6`: "Pure, with no runtime imports beyond time.ts". Line 20 imports `isoWeek` from `./roster.ts` at runtime.
  - Holding claims, for the record: `mock.ts` state on `globalThis` (`:689`) and the screens saying so (`dataIsMock`, `app/day/page.tsx:51`); `postgres.ts` calling `open_workday()`, `set_status()`, `end_workday()` without a time (`:862,891,920`); `MAX_REPORT_DAYS = 92` (`reports.ts:24`); `SourceConfig.tsx` naming no vendor (0 hits for hubspot|aircall|shopify) and its shortcut letters B N S F O A (`data-shortcut` at `:201,213,298,364,402,673`); `DayEditor.tsx` posting to `/api/v1/team/days/{userId}/{date}/corrections` (`:159`), Esc twice with changes (`dirty`/`armed`, `:136,201`), no literal status key; `PersonDialog.tsx` using `editChanges` (`:19`) and the directory routes; `MarketsConfig.tsx`'s seven database functions all exist in `db/`; `RosterPlanner.tsx`'s three routes; `FormsParts.tsx` a server component without a chart library (no `"use client"`, imports `next/link` and primitives only). `SourceConfig`'s "every answer re-reads the page" goes through a shared `save()` helper and was not followed to the fetch.
- Impact: the three stale sentences are the ones a newcomer would trust most (what errors exist, what a module imports, which layer is real).
- Recommendation: `types.ts`: "The mock implementation serves mock mode; `postgres.ts` implements the same interface against Postgres as cma_app; the choice is made in `index.ts`." `postgres.ts:35`: "CMA01 to CMA06". `reports.ts:6`: "beyond time.ts and roster.ts".
- README check: new.
- Disproof attempt: for each claim, grepped the code rather than trusting a nearby comment; for `reports.ts` confirmed `isoWeek` is a value import (no `type` keyword) and used at runtime.

### CQ-08: Test posture gaps that matter: no concurrency test, `proxy.ts` end-to-end only, mock/postgres parity by TypeScript alone, no API input fuzz
- Severity: Medium   Confidence: High   Effort: M
- Component: `web/verify/*`, `db/*verify*.sql`, `ingest/verify/*`
- Evidence:
  - What the pure web verifiers prove (observed from headers and check counts): corrections 31 (Madrid DST days, order rules, the diff), csv 17 (formats, quoting, formula defusing `verify/csv.mjs:48`, zone across the clock change, the Forms file), dashboard 17, live 39, team 26, roster 36 (parser, week across a month end, coverage, adherence around the clock change), configuration 99, messages 24, reports 91, signed-out 16, invitations 21, preview 18 (a property test), follow-up 25, copy (1728 keys, text rules only), import, datamap. Ingest's 14 pure verifiers: 452 checks in all (signature 18, mapping 48, hash 26, forms 48, aircall-token 20, aircall-mapping 49, aircall-scripts 27, shopify-signature 17, shopify-mapping 51, shopify-client 21, shopify-scripts 21, outbox 20, email-mapping 76, deploy-script 10); observed passing here.
  - Only dev or database verifiers prove: the routes (`api.mjs`, 300 `expect`s, needs the app and the dev database or a local one), the scheduler job (`scheduler.mjs`, needs `PGCONN` with the dev seed), theme, layout, hints (a built app on 8080), the IAP gate (`iap-token.mjs`, needs the app in iap mode against a test key set), and in ingest the five `*-flow.mjs` against a local PostgreSQL (`server.mjs` is reached by those three only).
  - Gap 1, concurrency (observed): `db/46_workday_window.sql:275-279` handles `unique_violation` on `cma.workday` ("a second tab opened the same day a moment earlier") by returning the existing row; a sequential second `open_workday` call never reaches it (the already-open check fires first), so the branch runs only in a race. No verify script, web verifier or ingest verifier runs two concurrent clock-ins or status changes: `grep -nE 'unique_violation|second tab|twice' db/*verify*.sql` finds other subjects only; `Promise.all` in `web/verify/api.mjs` (`:1173-1358`) parallelises reads of reports; the one real concurrency test in the repository is ingest's 200-order burst (`ingest/verify/shopify-flow.mjs:600`) and the `skip locked` claim (`db/30:500`). `for update` appears in 20 migration scripts and `pg_advisory` in 2; none is provoked by two sessions (no `dblink`, no `pg_background`, no second connection in any verifier).
  - Gap 2, `proxy.ts` (observed): tested by `iap-token.mjs` only (valid, missing, wrong audience or issuer, expired, future issue, wrong signer, spoofed headers), which needs the standalone server; the mock-mode branches (`?as=` redirect and cookie, `x-cma-mock-subject`, the 400 on a bad subject) are reached by `api.mjs` indirectly; `signed-out.mjs` reads the file as text. `proxy()` takes a `NextRequest` and returns a response, so a pure test is possible with a hand-built request and a stubbed `verifyIapJwt`.
  - Gap 3, mock/postgres parity (observed): `mockData: CmaData` and `postgresData: CmaData` (110 methods each) are the whole proof; the mock throws `CmaDbError` 122 times to mimic the database's refusals (`mock.ts:76,80,384,385` and so on) and nothing checks that the two refuse the same inputs, except `api.mjs` when Martin runs it in both data modes (its header says it runs against mock or api data). A refusal the mock has and the database lacks, or the reverse, is invisible to the pure verifiers and to the browser verifiers, which run in mock mode.
  - Gap 4, input robustness (observed): `jsonBody` (`respond.ts`) rejects non-JSON and non-object bodies; it has no size cap of its own (the platform's applies) and `api.mjs` has two malformed-input checks (`:1016` a malformed id, `:1522` a malformed invitation body); no property or fuzz test of a route exists. `lib/api/*.ts` validators are pure and could be fuzzed in minutes.
  - Gap 5 (observed): `nav.ts` and `period.ts` have no pure verifier; `layout.mjs` covers navigation per identity in a browser only.
  - A performance regression guard does not exist; 5.6 proposes one.
- Impact: the time model's one race (two tabs, or a double-click on Clock in with a slow network) is handled by code nobody has run; the gate every request passes has no test that runs without a deploy; a parity drift between mock and database would reach prod only through the api verifier Martin runs by hand.
- Recommendation (smallest useful set):
  1. A concurrency check with two connections. Without `dblink` the clean way is a pure Node check: `web/verify/concurrency.mjs` opening two `pg` clients to the local database (`CMA_DB_HOST` path), setting the same tenant and user, and running `select cma.open_workday()` in both after `begin` in one and before `commit` in the other; expect one `workday` row and one `start` event. Martin-run (needs a database), listed with `verify:scheduler`. A SQL-only variant would be a new verify pair (`db/76`/`77` per the brief's numbering) if `dblink` is acceptable on Cloud SQL; the Node form avoids the extension.
  2. `web/verify/proxy.mjs` (pure): import `proxy` from `../src/proxy.ts` under type stripping with `@/lib/auth/iap` stubbed through an env-selected JWKS as today, or refactor `proxy()` to take `verify` as a parameter with the real one as default; cover the four mock branches and the header stripping without a server.
  3. Parity: a pure verifier that runs the same refusal table (range over 92 days, unknown group, bad market, agent on a manager route) against `mockData` and against the SQL argument checks the database exposes as pure functions where they exist (`cma.forms_filters_check`); or at least extend `api.mjs`'s header to record that it must be run in both modes before a release (RUNBOOK line).
  4. A 10-line fuzz in `verify/api-params.mjs` (pure) over `dateParam`, `uuidParam`, `teamRangeParams`, `parseCallsFilter`, `parseFormsFilter` with random strings, long strings, unicode and `null` bytes: no throw other than `ApiError(400)`.
- README check: the PR check trigger is settled (Decision log, README line 1758: typecheck, lint, build and the pure verifiers wait until a second person commits), so the gaps are about what the verifiers prove, not about where they run. The verify-by-breaking rule is settled (`web/verify/README.md`). The concurrency test and the proxy test are new.
- Disproof attempt: searched every `db/*verify*.sql`, `web/verify/*.mjs` and `ingest/verify/*.mjs` for concurrency words and for a second connection; read `open_workday`'s body to confirm the branch is race-only; checked whether `api.mjs` or `scheduler.mjs` fires two clock-ins at once (they do not).

### CQ-09: Plain-JavaScript jobs are checked by lint and runtime only; web's lint leaves `no-undef` off for them
- Severity: Low   Confidence: High   Effort: S
- Component: `web/eslint.config.mjs`, `web/jobs/close-forgotten-workdays.mjs`, `ingest/eslint.config.mjs`, `ingest/jobs/*.mjs`
- Evidence:
  - Observed (`npx eslint --print-config`): web applies `eslint-config-next/core-web-vitals` + `typescript` to everything but `.next`, `out`, `build`, `next-env.d.ts`: 82 rules on for `jobs/*.mjs`, 86 for `src/**/*.ts`; `@typescript-eslint/no-explicit-any` error, `@typescript-eslint/no-unused-vars` warning only, `no-undef`, `eqeqeq`, `no-console`, `no-floating-promises` and the `no-unsafe-*` family off (no type-aware linting). `jobs/` and `verify/` are linted (21 files, 0 errors, 1 warning). `tsconfig.json` excludes `verify` and has `allowJs: false`, so neither `jobs/` nor `verify/` is type-checked.
  - Observed: ingest's config is `js.configs.recommended` (includes `no-undef` and `no-unused-vars` as errors) plus `eqeqeq: error` for `**/*.mjs`: stricter on JavaScript basics than web's config is for its own `.mjs` files.
  - Observed: `web/jobs/close-forgotten-workdays.mjs` (105 lines) duplicates `client.ts` (see CQ-04) and logs with `console.log`/`console.error` under its own prefix `close-forgotten-workdays:` (counts and dates only, as its comment says); its only end-to-end proof is `verify:scheduler` against the dev database (Martin). `ingest/jobs/*.mjs` are 51 lines in total, thin entry points over `src/jobs/*.mjs` through `runner.mjs` (argument parsing with shape checks, one `sync_run` row per run, codes never messages), which the pure verifiers reach through the flow verifiers only.
- Impact: in web's `.mjs` files a misspelt identifier passes lint and typecheck and fails at runtime, in a job that runs hourly against prod; `no-undef` would catch it at PR time for free.
- Recommendation:
  ```diff
  --- a/web/eslint.config.mjs
  +++ b/web/eslint.config.mjs
  @@
   const eslintConfig = defineConfig([
     ...nextVitals,
     ...nextTs,
  +  // Plain JavaScript (the scheduler's job and the verifiers) is not type-checked: let ESLint catch
  +  // an undefined identifier and a loose equality, as ingest's config does
  +  {
  +    files: ["jobs/**/*.mjs", "verify/**/*.mjs"],
  +    rules: { "no-undef": "error", eqeqeq: ["error", "always"] },
  +  },
  ```
  (`no-undef` needs Node globals: eslint-config-next already sets `languageOptions.globals` for node; verify with `npx eslint jobs verify` before committing.) Consider `"@typescript-eslint/no-unused-vars": "error"` for `src/**` once the one warning is fixed.
- README check: settled that the job is plain JavaScript without a build step (Decision log, 9 October 2026 night build); the lint rule is new.
- Disproof attempt: confirmed `no-undef` is off by `--print-config` (undefined, not 0); confirmed the lint run covered `jobs/` (file count 21 includes it).

### CQ-10: A real staff address is the default fixture identity in eight verifier files
- Severity: Low   Confidence: High   Effort: S
- Component: `web/verify/iap-token.mjs:30,51,64,65`, `ingest/verify/{flow,jobs-flow,aircall-flow,shopify-flow,outbox-flow,email-flow}.mjs` (header line and the `INGEST_FLOW_ADMIN_USER` default)
- Evidence (observed by grep over `web/verify` and `ingest/verify`, addresses masked here on purpose): of the addresses in verifier code, 81 are `@example.com`, 10 `@example.invalid`, 4 `@example.net`, 6 `@local.iam`, 18 `@pulse4all.com`. Of the 18, thirteen are one real staff address (the repository owner's) used as the default admin identity of the six ingest flow verifiers (`const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "<staff address>"`) and as the IAP token's `email` claim in `web/verify/iap-token.mjs:30`; the others are a three-letter mailbox at the same domain in `iap-token.mjs` (an alias, not a person) and the `hd` claim.
- Impact: CLAUDE.md (Security and data) says "No real personal or customer data in code, fixtures or tests; use the dev seed." The address is the owner's own and public on the organisation, so the exposure is nil; the rule is the point: the next person copying a flow verifier copies the pattern, and the repository is public until launch.
- Recommendation: default to the dev seed's style (`admin@example.com` or `agent.two@example.com` where the identity must exist in the seed) and keep the real address in the operator's environment variable only; in `iap-token.mjs` use `someone@example.com` with `hd: "example.com"` unless the app checks the domain (it matches on the Google `sub`, never on email: README Authentication).
- README check: settled rule (CLAUDE.md, Security and data; Decision log 5 October 2026 index 1679 on Google ids); the fixture is new.
- Disproof attempt: checked whether the flow verifiers need a real address to pass (they create throwaway tenants and people; the address is a label); checked that `iap-token.mjs`'s assertion on the address (`:51`) compares to its own constant, so any address works.

### CQ-11: `web/verify/README.md` documents 10 of 24 verify scripts
- Severity: Info   Confidence: High   Effort: S
- Component: `web/verify/README.md`
- Evidence: observed: the table lists copy, theme, layout, hints, dashboard, reports, follow-up, preview, api (two modes) and iap-token; `package.json` has 24 `verify:*` scripts (corrections, csv, live, team, roster, configuration, messages, signed-out, invitations, scheduler, import, datamap are missing from the table). The repository README's Code paragraph is complete and names each.
- Impact: the local README is where someone opening `web/verify/` looks first.
- Recommendation: one row per script, in the order of `npm run verify`; or replace the table with "see README, Code" and keep only the browser-verifier set-up notes.
- README check: new (documentation drift only).
- Disproof attempt: compared the table's script names with `grep '"verify:' web/package.json`.

### CQ-12: Git hygiene is clean; large tracked outputs are intended
- Severity: Info   Confidence: High   Effort: -
- Component: repository
- Evidence (observed): 2,430 tracked files; no `node_modules`, `.next`, `dist`, `.tsbuildinfo`, `.env` with values (`web/.env.example` holds names and empty values and a comment per variable) or coverage directories. Largest tracked files: `README.md` 748 KB, `web/src/fonts/Montserrat-VF.ttf` 728 KB (shipped on purpose), then screenshots of 290-390 KB under `records/0002-*` and `docs/b17d-forms/local-records/`. 144 PNGs, 12 `.log` files (verifier outputs under `docs/night-2026-10-16/local-records/web/`), 1,672 `.txt` files, 1,489 of them under `docs/*/local-records/` (14.6 MB), a convention the README references 30 times. `.gitignore` refuses filled people templates, rendered HubSpot projects and import CSVs; `web/.gitignore` is the Next default; `ingest/.gitignore` ignores `node_modules/`.
- Impact: none today; the repository grows by about 10 MB per night build through `docs/*/local-records`, which is a choice, not an accident.
- Recommendation: none required. If the growth bothers anyone, `docs/*/local-records/**/*.txt` could move to `records/` as the README already does for the dated run records; not a finding.
- README check: settled (README references `docs/night-*/local-records/` as the home of night-build outputs).
- Disproof attempt: `git ls-files -z | xargs -0 du -k | sort -nr`, extension histogram, grep of suspicious paths.

---

## Checked and found clean
- TypeScript strictness: `web/tsconfig.json` has `strict`, `noUncheckedIndexedAccess`, `noImplicitOverride`, `noFallthroughCasesInSwitch`, `isolatedModules`, `allowJs: false`; `npm run typecheck` (`next typegen && tsc --noEmit`) clean (observed).
- `any`: 0 in type positions; `as any`: 0; `@ts-ignore`/`@ts-expect-error`: 0; `as unknown as`: 2, both the documented `globalThis` slots (`mock.ts:689`, `client.ts:108`); 124 `as Type` casts, concentrated in `reports.ts` (10) and `api/configuration.ts` (9), each narrowing a parsed query value after a check.
- `eslint-disable`: 1, `DayEditor.tsx:117`, `react-hooks/exhaustive-deps` on a mount-only effect with a comment saying so.
- `npm run lint` in web: 0 errors, 1 warning (`verify/follow-up.mjs:43` unused `uid`); `jobs/` and `verify/` are linted (21 files). Ingest `npm run lint` clean; `npm test` (14 pure verifiers, 452 checks) all pass (observed).
- Placeholder parity between `en` and `nl`: 0 mismatches over 1728 keys (observed with `/var/tmp/5.7/copy-check.mjs`), so CQ-02 is about proof, not a present defect.
- No copy value is rendered as HTML: `dangerouslySetInnerHTML` and `innerHTML` 0 hits in `web/src`.
- Hashing and phone handling live in ingest only (`ingest/src/core/hash.mjs`; `libphonenumber-js` is an ingest dependency only); web never sees a phone number. Ingest does no time-zone arithmetic; business-day logic is in SQL (30 `cma.business_*`/workday functions) and `web/src/lib/time.ts`.
- Module boundary: 171 data imports all from `"@/lib/data"`, 0 from `postgres`/`mock`; 0 imports of `@/lib/auth/iap` outside `proxy.ts`; the 17 pure libraries have no runtime import outside the set (CQ-05 lists the two `CmaDbError` exceptions and `period.ts`'s alias); `lib/api/{calls,forms,configuration,roster}.ts` only validate.
- Ingest logging: one JSON logger, no `console.*`, no raw stdout writes, fields are ids of connections, codes, counts and durations; the `numbers` field (`aircall/read.mjs:220,246`) is a count; the `error` field (`jobs/poll-email.mjs:37`) is a code from `codeOf()`.
- Web logging: none of the eight lines logs a personal value (checked each argument).
- The big files are structured: `copy.ts` 44 top-level sections by screen; `mock.ts` 10 dated dividers by fixture; `postgres.ts` 17 dividers by migration with the `CmaData` object's 110 methods in interface order; `types.ts` 7 dividers. `ingest/src/core/store.mjs` (511 lines) heads with a table of every read and write it offers.
- Header claims: 27 of 30 checked hold (CQ-07 lists the three that do not).
- Ingest jobs: 51 lines of entry points over `src/jobs/`, arguments shape-checked in `runner.mjs:parseArgs`, failure codes never messages (`codeOf`), exit 1 when any connection failed with the others still served.
- `web/.env.example`: names, empty values and comments only.
- `tools/replay.mjs`: knip calls it unused; it is a documented operator tool (README Code paragraph, `docs/ingest/README.md`).

## Not checked / could not check
- `npm run build`, the browser verifiers (theme, layout, hints), `verify:api`, `verify:scheduler`, `verify:iap` and the ingest flow verifiers: not run here per the brief (the lead runs the build; the others need a server or the dev database). Their claims above are from headers and code.
- A precise non-null-assertion count: the 59 is a grep heuristic (identifier, `)` or `]` followed by `!` not followed by `=`); a TypeScript AST count was not taken.
- Whether `SourceConfig.tsx` re-reads the page after every write: it goes through a shared `save()` helper that was not followed to the fetch.
- Whether a `$`-bearing name exists in prod data today (no production access; the hazard is proven in Node, the trigger estimated as plausible).
- The security angle of the data/identity boundary (5.1) and the data-protection angle of ingest logging (5.2) are owned elsewhere; only consistency and maintainability were judged here.

## Commands run
- `npm run lint` in web → 0 errors, 1 warning (`/var/tmp/5.7/web-lint.txt`); `npm run typecheck` → clean (`/var/tmp/5.7/web-typecheck.txt`).
- `npm run lint` in ingest → clean; `npm test` → all pure verifiers pass, exit 0 (`/var/tmp/5.7/ingest-lint.txt`, `ingest-test.txt`).
- `npx --yes knip@5.50.5 --no-progress --reporter compact` in web → crashed (`ts.getDefaultLibFilePath is not a function`); `npx --yes -p typescript@5.9.3 -p knip@latest knip --no-progress --reporter compact` in web and ingest → reports in `/var/tmp/5.7/web-knip2.txt`, `ingest-knip.txt`; every web symbol cross-checked by `grep -rwl` over `web/src web/verify web/jobs tools`.
- `node /var/tmp/5.7/copy-check.mjs` → 1728 keys, 0 placeholder mismatches, 51 unused-leaf candidates, 10 confirmed by grep.
- `node /var/tmp/5.7/boundaries.mjs` (copied briefly into `web/verify/` to resolve `../src/`, then removed; `git status` clean) → 7 problems on the tree (the 4 reported in CQ-05 plus 3 for `respond.ts`, which the proposed diff exempts); `--provoke` → 11 problems, FAIL.
- `npx eslint --print-config` on `jobs/close-forgotten-workdays.mjs` and `src/lib/time.ts`; `npx eslint --format json jobs verify` → 21 files, 0 errors, 1 warning.
- Node one-liners proving the `$` expansion in `String.prototype.replace`/`replaceAll` with a string pattern.
- Greps over `web/src`, `ingest/src`, `db/*.sql`, `web/verify`, `ingest/verify`, README (indexed with `grep -n -o`), `docs/RUNBOOK.md`, `local-records/readme-index/decisions-index.md`; `git ls-files` size and extension histograms; `wc -l` per file.
