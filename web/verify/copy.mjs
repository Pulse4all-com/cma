/**
 * Verifier: copy rules from Pulse4all-Style.md section 4 and 5, applied to
 * src/lib/copy.ts (both languages).
 *
 *   node verify/copy.mjs             expect PASS, exit 0
 *   node verify/copy.mjs --provoke   feeds known-bad strings, expect FAIL, exit 1
 *
 * Rules: no exclamation marks; no trailing period on titles and labels (five
 * words or fewer); no all-caps words; no backend mechanics in copy; every key
 * present in every language; no empty strings.
 */
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../src/lib/copy.ts", import.meta.url), "utf8");

// Pull the two object literals out of the TypeScript without a compiler:
// strip types and `satisfies`, then evaluate as JS.
function extract(name) {
  const m = src.match(new RegExp(`const ${name}(?::\\s*Copy)? = (\\{[\\s\\S]*?\\n\\})(?: satisfies [^;]+)?;`));
  if (!m) throw new Error(`could not find const ${name} in copy.ts`);
  return Function(`return (${m[1]});`)();
}

const forbidden = /\b(webhook|api|scenario|payload|sync|token|jwt|iap|endpoint|database|server|proxy|cookie)\b/i;
const allCaps = /\b[A-Z]{3,}\b/;

function flatten(obj, prefix = "", out = {}) {
  for (const [k, v] of Object.entries(obj)) {
    const key = prefix ? `${prefix}.${k}` : k;
    if (typeof v === "string") out[key] = v;
    else flatten(v, key, out);
  }
  return out;
}

export function check(languages) {
  const problems = [];
  const flat = Object.fromEntries(Object.entries(languages).map(([l, o]) => [l, flatten(o)]));
  const allKeys = new Set(Object.values(flat).flatMap((f) => Object.keys(f)));
  for (const [lang, f] of Object.entries(flat)) {
    for (const key of allKeys) if (!(key in f)) problems.push(`${lang}: missing key ${key}`);
    for (const [key, text] of Object.entries(f)) {
      const words = text.trim().split(/\s+/).length;
      if (text.trim() === "") problems.push(`${lang}.${key}: empty`);
      if (text.includes("!")) problems.push(`${lang}.${key}: exclamation mark`);
      if (words <= 5 && /[.]$/.test(text.trim())) problems.push(`${lang}.${key}: trailing period on a label or title`);
      if (allCaps.test(text)) problems.push(`${lang}.${key}: all-caps word`);
      if (forbidden.test(text)) problems.push(`${lang}.${key}: backend mechanics in copy ("${text.match(forbidden)[0]}")`);
    }
  }
  return problems;
}

const provoke = process.argv.includes("--provoke");
const languages = { en: extract("en"), nl: extract("nl") };
if (provoke) {
  languages.en.myDay.title = "My day.";
  languages.nl.shell.testData = "Welkom! De API sync is bezig";
  delete languages.nl.nav.logOut;
}
const problems = check(languages);
for (const p of problems) console.log("  " + p);
const keyCount = Object.keys(flatten(languages.en)).length;
console.log(problems.length === 0 ? `copy: PASS (${keyCount} keys, en and nl)` : `copy: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
