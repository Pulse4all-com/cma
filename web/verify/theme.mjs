/**
 * Verifier: the running app uses only Pulse4all tokens (Pulse4all-Style.md
 * sections 2, 3 and 7): Montserrat is the only typeface, headings are Deep Blue
 * Heading, body text is Inkt Body, and every colour painted on screen comes
 * from the palette, SVG fills and strokes of the charts included. Also checks the
 * stylesheet removes Tailwind's default palette, so an off-brand class fails at
 * build time. The Dashboard is checked as the test supervisor, so its charts render;
 * My day is checked without a day (the Clock in card) and, as Agent Two after the
 * start route, with the clock and the status buttons; the Live board as the supervisor.
 *
 *   BASE=http://localhost:8080 node verify/theme.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/theme.mjs --provoke   injects an
 *       off-palette element and a stray font, expect FAIL, exit 1
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

const b = await chromium.launch();
const pages = [
  { path: "/" }, { path: "/day" }, { path: "/day", subject: "agent-two", start: true },
  { path: "/hours" }, { path: "/team/hours" },
  { path: "/reports/dashboard?range=month", subject: "supervisor" },
  { path: "/live/board", subject: "supervisor" },
  { path: "/logout" }, { path: "/no-access" },
];
for (const { path, subject, start } of pages) {
  // Clock in is an action: open the day through the route, so the page shows the clock
  if (start) await fetch(BASE + "/api/v1/me/day/start", { method: "POST", headers: { "x-cma-mock-subject": subject, "x-cma-request": "1" } });
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
    extraHTTPHeaders: subject ? { "x-cma-mock-subject": subject } : {},
  });
  const p = await ctx.newPage();
  await p.goto(BASE + path);
  await p.waitForLoadState("networkidle");
  if (provoke && path === "/") {
    await p.evaluate(() => {
      const el = document.createElement("p");
      el.textContent = "provoked";
      el.style.cssText = "color:#ff0000;font-family:Georgia,serif";
      document.querySelector("main")?.appendChild(el);
    });
  }
  const found = await p.evaluate(() => {
    const out = { fonts: new Set(), colours: [], headings: [], body: null };
    const vis = (el) => el.getClientRects().length > 0;
    for (const el of document.querySelectorAll("body *")) {
      if (!vis(el)) continue;
      const cs = getComputedStyle(el);
      out.fonts.add(cs.fontFamily.split(",")[0].trim().replace(/^["']|["']$/g, ""));
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
  for (const [sel, prop, value] of found.colours) {
    const hex = rgbToHex(value);
    if (hex && hex !== "transparent" && !palette.has(hex)) problems.push(`${path}: ${sel} ${prop} ${hex} is not in the palette`);
  }
  for (const [text, color] of found.headings) if (rgbToHex(color) !== "#2e61a6") problems.push(`${path}: heading "${text}" is ${rgbToHex(color)}, not Deep Blue Heading`);
  if (rgbToHex(found.body) !== "#1c2127") problems.push(`${path}: body text is ${rgbToHex(found.body)}, not Inkt Body`);
  await ctx.close();
}
await b.close();

const unique = [...new Set(problems)];
for (const x of unique) console.log("  " + x);
console.log(unique.length === 0 ? `theme: PASS (${pages.length} pages, palette incl. chart fills, Montserrat, heading and body colours)` : `theme: FAIL (${unique.length} problems)`);
process.exit(unique.length === 0 ? 0 : 1);
