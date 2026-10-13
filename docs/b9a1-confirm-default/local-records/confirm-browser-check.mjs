// The browser check of brief B9a.1 (13 October 2026), kept as a record of what was checked, not a verifier
// of the repository: the four irreversible confirmations in the standalone build in mock auth and data.
//   node confirm-check.mjs <base> <en|nl> <screenshot dir>   (Playwright from web/node_modules)
import { chromium } from "playwright";
const [base, lang, shots] = process.argv.slice(2);
const L = {
  en: { dissolve: "Dissolve", sentence: "Calls on a line that does not count are not stored, and switching a line off removes its stored calls." },
  nl: { dissolve: "Opheffen", sentence: "Gesprekken op een lijn die niet meetelt worden niet bewaard, en een lijn uitzetten verwijdert de bewaarde gesprekken." },
}[lang];
const out = [];
const ok = (name, pass, got) => out.push(`${pass ? "PASS" : "FAIL"}  ${name}${pass ? "" : `  (got ${JSON.stringify(got)})`}`);
const headers = (s) => ({ "x-cma-mock-subject": s, "x-cma-request": "1" });
for (const s of ["admin", "manager"]) {
  const r = await fetch(`${base}/api/v1/me/messages`, { headers: headers(s) });
  for (const m of (await r.json()).data?.messages ?? []) if (m.urgency === "urgent" && !m.acknowledgedAt)
    await fetch(`${base}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: headers(s) });
}
const b = await chromium.launch();
async function page(subject, path) {
  const ctx = await b.newContext({ viewport: { width: 1280, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
  const p = await ctx.newPage();
  const writes = [];
  p.on("request", (r) => { const u = new URL(r.url()); if (r.method() !== "GET" && u.pathname.startsWith("/api/v1/") && !u.pathname.startsWith("/api/v1/me/messages")) writes.push({ m: r.method(), path: u.pathname, body: r.postDataJSON?.() ?? null }); });
  await p.goto(base + path);
  await p.waitForLoadState("networkidle");
  return { ctx, p, writes };
}
const state = (p) => p.evaluate(() => {
  const d = document.querySelector("dialog[open]");
  if (!d) return null;
  const c = d.querySelector("[data-confirm]");
  return { cancel: document.activeElement?.hasAttribute("data-confirm-cancel") ?? false, focused: document.activeElement?.textContent?.trim(),
           destructive: !!c && c.className.includes("border-p4a-error") && !c.className.includes("bg-p4a-deepblue"), keycap: !!c?.querySelector("kbd"),
           text: d.textContent?.trim() };
});
async function opensOnCancel(where, p, writes, shot) {
  await p.locator("dialog[open]").waitFor({ timeout: 5000 });
  const s = await state(p);
  await p.screenshot({ path: `${shots}/${shot}-${lang}.png` });
  ok(`${where}: opens on Cancel (focus on "${s?.focused}")`, s?.cancel, s);
  ok(`${where}: the confirm button is the destructive secondary style without a keycap`, s?.destructive && !s?.keycap, s);
  await p.keyboard.press("Enter");
  await p.waitForTimeout(700);
  ok(`${where}: Enter at open cancels and writes nothing`, (await p.locator("dialog[open]").count()) === 0 && writes.length === 0, writes);
  return s;
}

// 1. Lines: Switch a counted line off
{
  const { ctx, p, writes } = await page("admin", "/configuration/sources/00000000-0000-7000-8000-00000000c002");
  const box = p.locator('[data-testid="source-lines"] input[type="checkbox"]').first();
  ok("lines: the first line counts", await box.isChecked(), false);
  await box.click();
  const s = await opensOnCancel("lines", p, writes, "lines-confirm");
  ok("lines: the confirmation carries the sentence", s?.text?.includes(L.sentence), s?.text);
  ok("lines: the box stayed ticked while the confirmation was open and after Enter", await box.isChecked(), false);
  await box.click();
  await p.locator("dialog[open]").waitFor({ timeout: 5000 });
  await p.keyboard.press("Escape");
  await p.waitForTimeout(400);
  ok("lines: Esc cancels and writes nothing", (await p.locator("dialog[open]").count()) === 0 && writes.length === 0 && await box.isChecked(), writes);
  await box.click();
  await p.locator("dialog[open]").waitFor({ timeout: 5000 });
  await p.locator("dialog[open] [data-confirm]").click();
  await p.waitForFunction(() => !document.querySelector('[data-testid="source-lines"] input[type="checkbox"]')?.checked, null, { timeout: 5000 }).catch(() => undefined);
  ok("lines: a click on the confirm button saves once and the box unticks after the save", writes.length === 1 && writes[0].body?.isCounted === false && !(await box.isChecked()), writes);
  await p.screenshot({ path: `${shots}/lines-after-confirm-${lang}.png` });
  await box.click();
  await p.waitForTimeout(800);
  ok("lines: switching it on again does not ask", (await p.locator("dialog[open]").count()) === 0 && await box.isChecked() && writes.at(-1)?.body?.isCounted === true, writes);
  await ctx.close();
}
// 2. Teams: Dissolve
{
  const { ctx, p, writes } = await page("admin", "/configuration/teams");
  await p.locator("main button", { hasText: new RegExp(`^${L.dissolve}$`) }).first().click();
  await opensOnCancel("teams dissolve", p, writes, "team-dissolve-confirm");
  await ctx.close();
}
// 3. Planner: Copy previous week (C)
{
  const { ctx, p, writes } = await page("manager", "/roster/planner");
  await p.keyboard.press("c");
  await opensOnCancel("planner copy previous week", p, writes, "roster-copy-confirm");
  await ctx.close();
}
// 4. My day: End workday (E), after clocking in through the API
{
  const r = await fetch(`${base}/api/v1/me/day/start`, { method: "POST", headers: headers("manager") });
  ok("my day: clocked in for the check", r.ok, r.status);
  const { ctx, p, writes } = await page("manager", "/day");
  await p.keyboard.press("e");
  await opensOnCancel("my day end workday", p, writes, "end-workday-confirm");
  await ctx.close();
}
await b.close();
console.log(out.join("\n"));
console.log(out.every((l) => l.startsWith("PASS")) ? `\nALL ${out.length} PASS` : `\n${out.filter((l) => !l.startsWith("PASS")).length} of ${out.length} FAILED`);
