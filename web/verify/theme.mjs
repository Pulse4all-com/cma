/**
 * Verifier: the running app uses only Pulse4all tokens (Pulse4all-Style.md
 * sections 2, 3 and 7): Montserrat is the only typeface, headings are Deep Blue
 * Heading, body text is Inkt Body, and every colour painted on screen comes
 * from the palette, SVG fills and strokes of the charts included. Also checks the
 * stylesheet removes Tailwind's default palette, so an off-brand class fails at
 * build time. The Dashboard is checked as the test supervisor, so its charts render;
 * My day is checked without a day (the Clock in card) and, as Agent Two after the
 * start route, with the clock and the status buttons; the Live board as the supervisor; People
 * (the Team screen, 0004) as the admin. The intake reports (B11): Speed to lead, Intake and Data quality
 * as the manager, Intake and the Dashboard's Intake row for a tenant without telephony or a shop;
 * since addition 0008i Inbound (by day as the manager, by hour as the analyst) and the Live board of a
 * tenant without telephony; on Inbound, the Live board and the telephony connection's Sources page every
 * table per docs/style/Pulse4all-Style.md 7.6 and 3.3 (header row, 14px cells at line-height 1.4, rows
 * of at least 40px, zebra rows). Since addition 0008j Calls (by day as the manager, by market as the
 * analyst, and for a tenant without telephony) and Calls per agent with a person's row and the not-linked
 * row opened, their tables per 7.6 and 3.3 as well. Since addition 0008p Forms (by day as the manager, by week as
 * the analyst), the Sources list with its form categories and the CRM connection's page, their tables too. Since
 * addition 0008t Email (by day as the manager, by week as the analyst, and for a tenant without email) and Email
 * per agent with a person's hours and the not-linked row opened; the CRM connection's page now holds its email
 * section (inboxes, mailboxes, channels). Since addition 0008u First orders (by day, week, market and level, and for a
 * tenant without an order pipeline) and Orders per person; the CRM connection's page now holds the order pipeline
 * switch and the stage outcomes. Since addition 0008v Campaign monitoring and a journey's page with its placeholders. Since
 * addition 0008y Attempts per deal (by day as the manager, by pipeline as the analyst, and for the invest tenant) and
 * Attempts per agent, their tables too. Since addition 0008zb Funnel (by week as the manager, by day as the reader) and
 * Cancellations, their bars and tables; the Sources list now holds the record kinds, and the CRM connection's page the
 * stages' read times, the reasons with their data-quality flags and the record kind rules.
 * On those report pages one header hint is opened by keyboard focus first, so the hint panel is
 * checked with the rest (palette, Montserrat), and its text must be Inkt Body on white like the
 * body text (12 October 2026). Since 16 October 2026 the rail folded to icons (cookie cma-rail) on
 * Welcome and Inbound, the hidden keycaps (cma-hints), the breadcrumbs, and the admin previewing as agent
 * (cma-preview-role: the banner and the select) on Welcome and My account. Since the IT audit of 17 October
 * 2026 no visible element is set in capitals by CSS (text-transform: uppercase) except a two-letter code such
 * as a market (style guide rule 4: the copy verifier cannot see a transform).
 *
 *   BASE=http://localhost:8080 node verify/theme.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/theme.mjs --provoke   injects an
 *       off-palette element in capitals and a stray font, greys out one hint panel and sets one Inbound table
 *       back to line-height 1.6, expect FAIL, exit 1
 *
 * Needs the app running in mock mode and Playwright's Chromium installed
 * (npx playwright install chromium).
 */
import { readFileSync } from "node:fs";
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");

const palette = new Set([
  "#ffffff", "#fffdf6", "#fdfbf1", "#eaf4fc", "#e3eefd", "#9ecff5", "#3b6fb3", "#265ba4", "#2e61a6",
  "#27ae6f", "#f4d9d0", "#0b133d", "#1c2127", "#666666", "#c98a1b", "#fbf1dc", "#b8433c", "#f8e4e1",
  "#e6f6ee", "#f3f4f6", "#d9e2ec", "#5b6472",
]);

function rgbToHex(rgb) {
  const m = rgb.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
  if (!m) return null;
  if (m[4] !== undefined && Number(m[4]) === 0) return "transparent";
  return "#" + [m[1], m[2], m[3]].map((n) => Number(n).toString(16).padStart(2, "0")).join("");
}

const problems = [];

// Static: the stylesheet must drop Tailwind's default colours
const css = readFileSync(new URL("../src/app/globals.css", import.meta.url), "utf8");
if (!css.includes("--color-*: initial")) problems.push("globals.css does not remove Tailwind's default palette");
for (const hex of css.matchAll(/#[0-9a-f]{6}\b/gi)) {
  if (!palette.has(hex[0].toLowerCase())) problems.push(`globals.css: colour ${hex[0]} is not in the palette`);
}

/**
 * The mock's urgent fixture message pops up for every identity but the first one to poll the inbox, and
 * its dialog holds the focus, so a header hint could never open on a fresh server for the others (seen on
 * main, 13 October 2026). Acknowledge it first for the identities read here, as a person would.
 */
async function acknowledgeUrgent(subject) {
  const r = await fetch(`${BASE}/api/v1/me/messages`, { headers: { "x-cma-mock-subject": subject } }).catch(() => null);
  const list = (await r?.json().catch(() => null))?.data?.messages ?? [];
  for (const m of list) {
    if (m.urgency === "urgent" && !m.acknowledgedAt) {
      await fetch(`${BASE}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: { "x-cma-mock-subject": subject, "x-cma-request": "1" } });
    }
  }
}
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst"]) await acknowledgeUrgent(subject);
// The security headers (next.config.ts): the first CSP step of the IT audit of 17 October 2026 on a page, a
// route and the proxy's 401 alike; provoked, the expected policy is a different one
{
  const expected = provoke ? "frame-ancestors 'self'" : "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'";
  for (const [path, headers] of [["/", { "x-cma-mock-subject": "agent-two" }], ["/api/v1/me", { "x-cma-mock-subject": "agent-two" }], ["/day", { "x-cma-mock-subject": "no-such-person-" + "x".repeat(70) }]]) {
    const r = await fetch(BASE + path, { headers, redirect: "manual" });
    const csp = r.headers.get("content-security-policy");
    if (csp !== expected) problems.push(`${path}: content-security-policy is ${JSON.stringify(csp)}, not ${JSON.stringify(expected)}`);
    if (r.headers.get("x-content-type-options") !== "nosniff") problems.push(`${path}: x-content-type-options is not nosniff`);
    if (r.headers.get("x-frame-options") !== "DENY") problems.push(`${path}: x-frame-options is not DENY`);
  }
}
const b = await chromium.launch();
const pages = [
  { path: "/" }, { path: "/day" }, { path: "/day", subject: "agent-two", start: true },
  { path: "/hours" }, { path: "/team/hours" },
  { path: "/reports/dashboard?range=month", subject: "supervisor" },
  { path: "/live/board", subject: "supervisor", tables: true },
  { path: "/team/people", subject: "admin" },
  { path: "/roster/planner", subject: "manager" },
  { path: "/roster/planner/print", subject: "manager" },
  { path: "/schedule" },
  { path: "/messages" }, { path: "/messages/send", subject: "supervisor" },
  // My account (0005b): with teams and skills, and for someone without a clock
  { path: "/account" }, { path: "/account", subject: "analyst" },
  // The configuration screens (0005a), as the admin
  { path: "/configuration/statuses", subject: "admin" }, { path: "/configuration/teams", subject: "admin" },
  { path: "/configuration/absences", subject: "admin" }, { path: "/configuration/exports", subject: "admin" },
  { path: "/configuration/app-links", subject: "admin" },
  // Sources, a connection of each kind, Markets and Alert rules (addition 0008e), as the admin
  { path: "/configuration/sources", subject: "admin" },
  { path: "/configuration/sources/00000000-0000-7000-8000-00000000c001", subject: "admin" },
  { path: "/configuration/sources/00000000-0000-7000-8000-00000000c002", subject: "admin", tables: true },
  { path: "/configuration/sources/00000000-0000-7000-8000-00000000c003", subject: "admin" },
  { path: "/configuration/markets", subject: "admin" },
  { path: "/configuration/alert-rules", subject: "admin" },
  // The metric catalog (Configuration → Metrics): the page as the admin
  { path: "/configuration/metrics", subject: "admin" },
  // System health (addition 0008r), as the admin
  { path: "/configuration/health", subject: "admin" },
  // The intake reports (B11): as the manager (every figure), and the tenant without telephony or a shop
  { path: "/reports/speed-to-lead?range=month&group=agent", subject: "manager" },
  { path: "/reports/intake?range=month", subject: "manager" },
  { path: "/reports/intake?range=month", subject: "invest-analyst" },
  { path: "/reports/data-quality", subject: "manager" },
  { path: "/reports/dashboard?range=month", subject: "invest-analyst" },
  // Inbound and the Live board's inbound part (addition 0008i): the reasons' series and the bars, and the
  // board of a tenant without telephony
  { path: "/reports/inbound?range=month", subject: "manager", tables: true },
  { path: "/reports/inbound?range=month&group=hour", subject: "analyst", tables: true },
  { path: "/live/board", subject: "invest-analyst" },
  // Calls and Calls per agent (addition 0008j): the tiles, the bars and the tag table by day and by market,
  // the per-agent table with a person's row and the not-linked row opened, and a tenant without telephony
  { path: "/reports/calls?range=month", subject: "manager", tables: true },
  { path: "/reports/calls?range=month&group=market", subject: "analyst", tables: true },
  { path: "/reports/calls-per-agent?range=month", subject: "manager", tables: true, expand: true },
  // a tenant without telephony: the page says so in words and has no header to explain
  { path: "/reports/calls?range=month", subject: "invest-analyst", noHint: true },
  // Follow-up and Waiting for you (addition 0008o): the tiles, the three tables and the per-person table; the
  // attention filter; the person's own rows
  { path: "/reports/follow-up", subject: "manager", tables: true },
  { path: "/reports/follow-up?state=attention", subject: "supervisor", tables: true },
  { path: "/me/follow-up", tables: true },
  // Forms (addition 0008p): the tiles, the columns, the grouped tables, the resolution bars in the series order,
  // by day as the manager and by week as the analyst; Sources with the form categories and the CRM connection's
  // forms with their polled and category columns
  { path: "/reports/forms?range=month", subject: "manager", tables: true },
  { path: "/reports/forms?range=month&group=week", subject: "analyst", tables: true },
  // Email and Email per agent (addition 0008t): the tiles, the received columns per inbox and per mailbox in the
  // series order, the sent columns, the tables by inbox, mailbox, category and market, waiting and not responding,
  // by day as the manager and by week as the analyst; the per-person table with a person's hours and the
  // not-linked row opened; a tenant without email
  { path: "/reports/email?range=month", subject: "manager", tables: true },
  { path: "/reports/email?range=month&group=week", subject: "analyst", tables: true },
  { path: "/reports/email-per-agent?range=month", subject: "manager", tables: true, expand: true },
  { path: "/reports/email?range=month", subject: "invest-analyst", noHint: true },
  // First orders and Orders per person (addition 0008u): the tiles, the columns in the series order (call center
  // Deep Blue, self-service Leaf Green), the level bars, the tables by market and level, the amounts and the order
  // list with its evidence badges, by day as the manager and by week as the analyst; the per-person table; a tenant
  // without an order pipeline
  { path: "/reports/first-orders?range=month", subject: "manager", tables: true },
  { path: "/reports/first-orders?range=month&group=week", subject: "analyst", tables: true },
  { path: "/reports/first-orders?range=month&group=market", subject: "manager", tables: true },
  { path: "/reports/first-orders?range=month&group=level", subject: "analyst", tables: true },
  { path: "/reports/orders-per-person?range=month", subject: "manager", tables: true },
  { path: "/reports/first-orders?range=month", subject: "invest-analyst", noHint: true },
  // Attempts per deal and Attempts per agent (addition 0008y): the tiles with their deltas (Leaf Green better, the error
  // colour worse), the bars per attempt, reach, won rate and time since the last attempt (Deep Blue, Light Blue), the
  // table per group and the deal list with its links, by day as the manager, by pipeline with every counted deal as the
  // analyst; the per-agent table with its bars; a tenant without the per-person switch
  { path: "/reports/attempts?range=month", subject: "manager", tables: true },
  { path: "/reports/attempts?range=month&group=pipeline&attempted=some&outcome=won", subject: "analyst", tables: true },
  { path: "/reports/attempts-per-agent?range=month", subject: "manager", tables: true },
  { path: "/reports/attempts?range=month", subject: "invest-analyst", tables: true },
  // Funnel and Cancellations (addition 0008zb): the tiles with their deltas, the stage bars (Deep Blue), the real reasons
  // and the no-reason and data-quality bars (Light Blue), the tables per stage, pipeline, market, source and week or day,
  // the list without a reason and deals per person, by week as the manager and by day as the reader; the requests per
  // market, reasons and week, the newest requests with their badges
  { path: "/reports/funnel?range=month", subject: "manager", tables: true },
  { path: "/reports/funnel?range=month&group=day", subject: "reader", tables: true },
  { path: "/reports/cancellations?range=month", subject: "manager", tables: true },
  { path: "/reports/cancellations?range=month&group=day", subject: "analyst", tables: true },
  // Reviews (addition 0008ze): the tiles, the bars per rating, link level and invitation event (Deep Blue, the unlinked and
  // the reviews without an event in the neutral hue), the tables per market, week or day and channel, the markets' states
  { path: "/reports/reviews?range=month", subject: "manager", tables: true },
  { path: "/reports/reviews?range=month&group=day", subject: "reader", tables: true },
  // Maintenance (addition 0008zi): the grid with Overdue and the months, a figure's device list in the Components view, and a
  // tenant without an asset register
  { path: "/reports/maintenance", subject: "manager", tables: true },
  { path: "/reports/maintenance?view=components&bucket=overdue", subject: "reader", tables: true },
  { path: "/reports/maintenance", subject: "invest-analyst" },
  // Campaign monitoring (addition 0008v): the journeys' cards with their status badges and design link, a journey's
  // Muted banner, dashed placeholders and unticked prerequisites; a tenant without journeys
  { path: "/campaigns", subject: "manager" },
  { path: "/campaigns/fca-uk-consumers", subject: "analyst" },
  { path: "/campaigns", subject: "invest-analyst" },
  { path: "/configuration/sources", subject: "admin", tables: true },
  { path: "/configuration/sources/00000000-0000-7000-8000-00000000c001", subject: "admin", tables: true },
  { path: "/logout" }, { path: "/no-access" },
  // The folded rail and the hidden hints (16 October 2026), the admin previewing as agent (the banner, the select)
  { path: "/", cookies: { "cma-rail": "collapsed" } },
  { path: "/reports/inbound?range=month", subject: "manager", cookies: { "cma-rail": "collapsed", "cma-hints": "hidden" }, tables: true },
  { path: "/", subject: "admin", cookies: { "cma-preview-role": "agent" } },
  { path: "/account", subject: "admin", cookies: { "cma-preview-role": "agent" } },
  // Invitations (addition 0008l): the link for an account that is no person yet, open and for another account
  { path: `/invite/${"mock-open-invitation".padEnd(43, "0")}`, subject: "invitee-one" },
  { path: `/invite/${"mock-open-invitation".padEnd(43, "0")}`, subject: "invitee-other" },
];
let hintsChecked = 0;
let tablesChecked = 0;
const hintsSkipped = [];
for (const { path, subject, start, tables, expand, noHint, cookies } of pages) {
  // Clock in is an action: open the day through the route, so the page shows the clock
  if (start) await fetch(BASE + "/api/v1/me/day/start", { method: "POST", headers: { "x-cma-mock-subject": subject, "x-cma-request": "1" } });
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
    extraHTTPHeaders: subject ? { "x-cma-mock-subject": subject } : {},
  });
  // The frame's preferences and the preview are cookies (16 October 2026); a signed-in browser carries its session
  // (Welcome on open, addition 0008z), so a page opened without the verifiers' header opens as asked, not on Welcome
  await ctx.addCookies(Object.entries({ "cma-session": "1", ...cookies }).map(([name, value]) => ({ name, value, domain: new URL(BASE).hostname, path: "/" })));
  const p = await ctx.newPage();
  await p.goto(BASE + path);
  await p.waitForLoadState("networkidle");
  // Calls per agent: open the first person's row and the not-linked row, so their splits are checked too
  if (expand) {
    // Email per agent (addition 0008t): the same with its own row names and the hours per person
    const x = path.startsWith("/reports/email-per-agent") ? "email-agent" : "agent";
    await p.locator(`[data-testid="${x}-toggle"]`).first().click();
    await p.locator(`[data-testid="${x}-not-linked"] [data-testid="${x}-toggle"]`).click();
    if (await p.locator(`[data-testid="${x === "agent" ? "agent-split" : "email-agent-hours"}"]`).count() !== 2) problems.push(`${path}: the rows did not open`);
    await p.mouse.move(0, 0);
  }
  // A report page: open one header hint by keyboard focus, so the panel is painted when the colours
  // are read. An urgent alert's dialog holds the focus where one is waiting (the supervisor's), so
  // that page is read without a hint; the other report pages must each show one
  if (path.startsWith("/reports/") && !noHint) {
    const mark = p.locator("main button[data-header-hint]").first();
    if (await mark.count() === 0) problems.push(`${path}: no header hint to open`);
    else {
      await mark.focus();
      const hint = await p.evaluate((grey) => {
        const m = document.activeElement;
        if (!m?.hasAttribute("data-header-hint")) return document.querySelector("dialog[open]") ? "dialog" : null;
        const panel = document.getElementById(m.getAttribute("aria-describedby") ?? "");
        if (!panel || panel.hidden) return null;
        if (grey) panel.style.color = "#666666";
        const cs = getComputedStyle(panel);
        return { color: cs.color, background: cs.backgroundColor };
      }, provoke && path.startsWith("/reports/data-quality"));
      if (hint === "dialog") hintsSkipped.push(`${path} as ${subject}`);
      else if (!hint) problems.push(`${path}: the header hint does not open on focus`);
      else {
        hintsChecked++;
        if (rgbToHex(hint.color) !== "#1c2127") problems.push(`${path}: hint text is ${rgbToHex(hint.color)}, not Inkt Body like the other text`);
        if (rgbToHex(hint.background) !== "#ffffff") problems.push(`${path}: hint panel is ${rgbToHex(hint.background)}, not white`);
      }
    }
  }
  if (path === "/" && cookies?.["cma-preview-role"] && await p.locator('[data-testid="preview-banner"]').count() !== 1) problems.push(`${path}: the preview banner is missing for the previewing admin`);
  if (cookies?.["cma-rail"] === "collapsed" && Math.round(await p.locator("nav[data-rail-nav]").evaluate((n) => n.getBoundingClientRect().width)) !== 64) problems.push(`${path}: the folded rail is not 64px`);
  if (provoke && path === "/" && !cookies) {
    await p.evaluate(() => {
      const el = document.createElement("p");
      el.textContent = "provoked";
      el.style.cssText = "color:#ff0000;font-family:Georgia,serif;text-transform:uppercase";
      document.querySelector("main")?.appendChild(el);
    });
  }
  const found = await p.evaluate(() => {
    const out = { fonts: new Set(), colours: [], headings: [], body: null, capitals: [] };
    const vis = (el) => el.getClientRects().length > 0;
    for (const el of document.querySelectorAll("body *")) {
      if (!vis(el)) continue;
      const cs = getComputedStyle(el);
      out.fonts.add(cs.fontFamily.split(",")[0].trim().replace(/^["']|["']$/g, ""));
      // Capitals by CSS (style guide rule 4): only two-letter codes, such as a team's markets, may be set that way
      if (cs.textTransform === "uppercase" && !/^([A-Za-z]{2})(\s+[A-Za-z]{2})*$/.test(el.textContent?.trim() ?? "")) {
        out.capitals.push(`${el.tagName.toLowerCase()} "${(el.textContent ?? "").trim().slice(0, 30)}"`);
      }
      const props = ["color", "backgroundColor", "borderTopColor", "outlineColor"];
      // Chart marks and icons: what an SVG paints is its fill and stroke
      if (el instanceof SVGElement && el.tagName.toLowerCase() !== "svg" && el.tagName.toLowerCase() !== "g") props.push("fill", "stroke");
      for (const prop of props) {
        const cls = typeof el.className === "string" ? el.className : el.className?.baseVal ?? "";
        out.colours.push([el.tagName.toLowerCase() + (cls ? "." + cls.split(" ")[0] : ""), prop, cs[prop]]);
      }
    }
    for (const h of document.querySelectorAll("h1, h2")) if (vis(h)) out.headings.push([h.textContent?.trim().slice(0, 30), getComputedStyle(h).color]);
    out.body = getComputedStyle(document.body).color;
    return { ...out, fonts: [...out.fonts] };
  });
  for (const f of found.fonts) if (!/montserrat/i.test(f)) problems.push(`${path}: typeface "${f}" is not Montserrat`);
  for (const c of found.capitals) problems.push(`${path}: ${c} is set in capitals by CSS (style guide rule 4)`);
  for (const [sel, prop, value] of found.colours) {
    const hex = rgbToHex(value);
    if (hex && hex !== "transparent" && !palette.has(hex)) problems.push(`${path}: ${sel} ${prop} ${hex} is not in the palette`);
  }
  for (const [text, color] of found.headings) if (rgbToHex(color) !== "#2e61a6") problems.push(`${path}: heading "${text}" is ${rgbToHex(color)}, not Deep Blue Heading`);
  if (rgbToHex(found.body) !== "#1c2127") problems.push(`${path}: body text is ${rgbToHex(found.body)}, not Inkt Body`);
  // Tables and data grids on this pull request's screens (docs/style/Pulse4all-Style.md 7.6 and 3.3, addition
  // 0008i): a Background Blue header row in 13px Semi Bold Deep Blue Heading; body cells at 14px or smaller,
  // Inkt Body or Muted, with line-height 1.4; rows of at least 40px; zebra rows in Warm Off-White. --provoke
  // sets the manager's Inbound table back to the prose line-height
  if (tables) {
    const t = await p.evaluate((spoil) => {
      const hex = (c) => { const m = /rgba?\((\d+), (\d+), (\d+)/.exec(c); return m ? "#" + [m[1], m[2], m[3]].map((n) => Number(n).toString(16).padStart(2, "0")).join("") : c; };
      if (spoil) document.querySelector('[data-testid="inbound-table"]')?.style.setProperty("line-height", "1.6");
      const out = { tables: 0, problems: [] };
      for (const table of document.querySelectorAll("main table")) {
        if (table.getClientRects().length === 0) continue;
        out.tables++;
        const id = table.dataset.testid ?? "a table";
        const bad = new Set();
        for (const th of table.querySelectorAll("thead th")) {
          if (th.getClientRects().length === 0) continue;
          const cs = getComputedStyle(th);
          const bg = [th.closest("tr"), th.closest("thead")].map((e) => getComputedStyle(e).backgroundColor);
          if (cs.fontSize !== "13px" || cs.fontWeight !== "600" || hex(cs.color) !== "#2e61a6") bad.add(`header ${cs.fontSize} ${cs.fontWeight} ${hex(cs.color)}`);
          if (!bg.some((c) => hex(c) === "#eaf4fc")) bad.add("header row not Background Blue");
        }
        const rows = [...table.querySelectorAll("tbody tr")];
        rows.forEach((tr, i) => {
          if (tr.getBoundingClientRect().height < 39.5) bad.add(`a row of ${Math.round(tr.getBoundingClientRect().height)}px`);
          if (i % 2 === 1 && hex(getComputedStyle(tr).backgroundColor) !== "#fdfbf1") bad.add("no zebra rows");
          for (const td of tr.children) {
            const cs = getComputedStyle(td);
            if (parseFloat(cs.fontSize) > 14) bad.add(`a cell of ${cs.fontSize}`);
            if (Math.abs(parseFloat(cs.lineHeight) / parseFloat(cs.fontSize) - 1.4) > 0.02) bad.add(`cells at line-height ${(parseFloat(cs.lineHeight) / parseFloat(cs.fontSize)).toFixed(2)}`);
            if (!["#1c2127", "#5b6472"].includes(hex(cs.color))) bad.add(`a cell in ${hex(cs.color)}`);
          }
        });
        for (const x of bad) out.problems.push(`${id}: ${x}`);
      }
      return out;
    }, provoke && path === "/reports/inbound?range=month" && subject === "manager");
    if (t.tables === 0) problems.push(`${path}: no table to check`);
    tablesChecked += t.tables;
    for (const x of t.problems) problems.push(`${path}: ${x} (7.6, 3.3)`);
  }
  await ctx.close();
}
await b.close();
if (hintsChecked < 5) problems.push(`only ${hintsChecked} report pages showed a header hint, expected 5`);

const unique = [...new Set(problems)];
for (const x of unique) console.log("  " + x);
console.log(unique.length === 0 ? `theme: PASS (${pages.length} pages, palette incl. chart fills, Montserrat, heading and body colours, no capitals by CSS, ${tablesChecked} tables per 7.6 and 3.3, a header hint open on ${hintsChecked} report pages${hintsSkipped.length ? `; not on ${hintsSkipped.join(", ")}, where an alert dialog holds the focus` : ""})` : `theme: FAIL (${unique.length} problems)`);
process.exit(unique.length === 0 ? 0 : 1);
