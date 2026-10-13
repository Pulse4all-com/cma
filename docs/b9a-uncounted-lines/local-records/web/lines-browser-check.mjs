// The browser check of Configuration → Sources → Lines run for brief B9a (13 October 2026), kept as a
// record of what was checked, not a verifier of the repository. Against the standalone build in mock
// auth and data, with Playwright from web/node_modules and Chromium:
//   CHROME_EXE=<chromium> node lines-browser-check.mjs http://localhost:8080 en <screenshot dir>
//   (and a second server with CMA_DEFAULT_LOCALE=nl for nl)
// Scratch browser check (not committed): the Lines section's Counted hint and the switch-off confirmation
import { chromium } from "playwright";
const [base, lang, shots] = process.argv.slice(2);
const WANT = {
  en: "Calls on a line that does not count are not stored, and switching a line off removes its stored calls.",
  nl: "Gesprekken op een lijn die niet meetelt worden niet bewaard, en een lijn uitzetten verwijdert de bewaarde gesprekken.",
}[lang];
const out = [];
const ok = (name, pass, got) => out.push(`${pass ? "PASS" : "FAIL"}  ${name}${pass ? "" : `  (got ${JSON.stringify(got)})`}`);
for (const s of ["admin"]) {
  const r = await fetch(`${base}/api/v1/me/messages`, { headers: { "x-cma-mock-subject": s } });
  for (const m of (await r.json()).data?.messages ?? []) if (m.urgency === "urgent" && !m.acknowledgedAt)
    await fetch(`${base}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: { "x-cma-mock-subject": s, "x-cma-request": "1" } });
}
const b = await chromium.launch({ executablePath: process.env.CHROME_EXE });
const ctx = await b.newContext({ viewport: { width: 1280, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "admin" } });
const p = await ctx.newPage();
await p.goto(`${base}/configuration/sources/00000000-0000-7000-8000-00000000c002`);
const table = p.locator('[data-testid="source-lines"]');
await table.waitFor();
// the Counted header's hint
const ths = table.locator("th");
const countedTh = ths.nth(3);
const mark = countedTh.locator("button[data-header-hint]");
await mark.focus();
const panelId = await mark.getAttribute("aria-describedby");
const hintText = (await p.locator(`[id="${panelId}"]`).textContent())?.trim();
ok("the Counted hint says calls on an uncounted line are not stored and switching off removes them", hintText?.includes(WANT), hintText);
await p.keyboard.press("Escape");
const boxes = table.locator('input[type="checkbox"]');
const first = boxes.first();
const name = (await table.locator("tbody tr").first().locator("td").first().locator("span.font-semibold").textContent())?.trim();
ok("the first line counts at the start", await first.isChecked(), await first.isChecked());
// switching off asks first
await first.click();
const dialog = p.locator("dialog[open]");
await dialog.waitFor({ timeout: 5000 });
const dText = (await dialog.textContent())?.trim();
ok("switching a line off asks for confirmation with that sentence and the line's name", dText?.includes(WANT) && dText?.includes(name), dText);
await p.screenshot({ path: `${shots}/lines-confirm-${lang}.png` });
ok("…and nothing is saved while it asks", await first.isChecked(), await first.isChecked());
// cancel keeps it counted
await dialog.locator("button").filter({ hasText: lang === "en" ? "Cancel" : "Annuleren" }).click();
await p.waitForTimeout(300);
ok("cancel keeps the line counted", (await p.locator("dialog[open]").count()) === 0 && await first.isChecked(), await first.isChecked());
// confirm switches it off
await first.click();
await dialog.waitFor({ timeout: 5000 });
await dialog.locator("button").first().click();
await p.waitForTimeout(800);
ok("confirm switches the line off", !(await first.isChecked()) && (await p.locator("dialog[open]").count()) === 0, await first.isChecked());
// switching on does not ask
await first.click();
await p.waitForTimeout(800);
ok("switching a line on does not ask, and it counts again", (await p.locator("dialog[open]").count()) === 0 && await first.isChecked(), await first.isChecked());
await p.screenshot({ path: `${shots}/lines-after-${lang}.png` });
await b.close();
console.log(out.join("\n"));
console.log(out.every((l) => l.startsWith("PASS")) ? `\nALL ${out.length} PASS` : `\n${out.filter((l) => !l.startsWith("PASS")).length} of ${out.length} FAILED`);
