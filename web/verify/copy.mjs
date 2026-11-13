/**
 * Verifier: copy rules from Pulse4all-Style.md section 4 and 5, applied to
 * src/lib/copy.ts (both languages).
 *
 *   node verify/copy.mjs             expect PASS, exit 0
 *   node verify/copy.mjs --provoke   feeds known-bad strings, expect FAIL, exit 1
 *
 * Rules: no exclamation marks; no trailing period on titles and labels (five
 * words or fewer); no all-caps words; no backend mechanics in copy; every key
 * present in every language; no empty strings. Since 12 November 2026 also where
 * the catalog travels: no client component takes the whole catalog or every hint
 * (wholeCatalogToClient, below); --provoke reads three bad samples as files.
 */
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

/** Every .tsx under a directory */
function tsxUnder(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? tsxUnder(path.join(dir, e.name)) : e.name.endsWith(".tsx") ? [path.join(dir, e.name)] : []));
}

/** A file is a client file when its first statement is "use client" (comments before it allowed) */
const isClientText = (text) => /^\s*(?:\/\*[\s\S]*?\*\/\s*|\/\/[^\n]*\n\s*)*["']use client["']/.test(text);

/** Does a client file type something as the whole catalog: `: Copy` (or Readonly<Copy>) that is not `Copy["part"]` */
export const typesWholeCopy = (text) => /:\s*(?:Readonly<\s*)?Copy\b(?!\s*\[)/.test(text);

/**
 * Every attribute of every component's opening tag in a file, as { name, value }: the tag is walked with its braces
 * counted, so an earlier attribute holding JSX, an arrow or a comparison does not end it. value is the text between the
 * attribute's braces
 */
export function componentAttributes(text) {
  const out = [];
  for (const m of text.matchAll(/<([A-Z][A-Za-z0-9.]*)\b/g)) {
    let depth = 0; let i = m.index + m[0].length; let from = -1;
    for (; i < text.length; i += 1) {
      const ch = text[i];
      if (ch === "{") { if (depth === 0) from = i + 1; depth += 1; }
      else if (ch === "}") {
        depth -= 1;
        // an attribute's value (`name={…}`), not a spread and not children
        if (depth === 0 && from >= 0 && /=\s*$/.test(text.slice(0, from - 1))) out.push({ name: m[1], value: text.slice(from, i).trim() });
        if (depth === 0) from = -1;
      } else if (ch === ">" && depth === 0 && text[i - 1] !== "=") break;
    }
  }
  return out;
}

/**
 * The components handed the bare catalog: the attribute's value is `copy` itself, or a branch of a choice (`cond ? copy
 * : x`, `x ?? copy`). An argument of a call (pickCopy(copy, …), a page's own slicing helper) is not the catalog travelling
 */
export const handedBareCatalog = (text) => componentAttributes(text)
  .filter(({ value: v }) => v === "copy" || /[?:]\s*copy\s*(?:$|:)/.test(v) || /(?:\?\?|\|\||&&)\s*copy\s*$/.test(v)).map((a) => a.name);

/**
 * The components handed every hint (the catalog's largest part): pickCopy(…, "hints"), or an object with a `hints:` key
 * whose value is anything but pickHints(…) (the catalog's hints under their own name or a page's alias such as `h`)
 */
export const handedEveryHint = (text) => componentAttributes(text)
  .filter(({ value: v }) => /pickCopy\(copy,[^)]*"hints"/.test(v) || /(?:^|[{,\s])hints\s*:(?!\s*pickHints\()/.test(v)).map((a) => a.name);

/**
 * Client components that take the whole catalog, and server files that hand one the bare catalog or every hint. A
 * component of a client file handed the catalog from another client file is fine (nothing travels), so only server
 * files are read for the hand-over. What the rule holds, exactly: a client file's `: Copy` annotation under any name; a
 * bare `copy` as an attribute's value (or a branch of it) on a client component in a server file; and a `hints` handed
 * otherwise than through pickHints. A catalog that travels under another variable's name or through a spread is not
 * seen (none exists; verify:perf's HTML budgets are the other guard). The detectors, and the collection of the client
 * components' names, are shown to work on every run: each must flag its known-bad samples and pass its good ones
 */
export function wholeCatalogToClient(provoked = false) {
  const srcDir = fileURLToPath(new URL("../src", import.meta.url));
  // samples of the forms the rule must catch and must leave alone; the bad ones are also what --provoke reads as files
  const badClient = '"use client";\nexport function ProvokedClient({ copy }: { copy: Copy }) { return null; }\nexport const ProvokedOther = ({ words }: { words: Readonly<Copy>; }) => null;';
  const badServer = [
    '<ProvokedClient lines={x.filter((l) => l.n > 1)} empty={<Empty />} copy={copy} />',
    '<ProvokedOther t={ok ? copy : other} />',
    '<ProvokedClient copy={pickCopy(copy, "team", "hints")} />',
    '<ProvokedClient copy={{ ...pickCopy(copy, "team"), hints: h }} />',
  ];
  const goodClient = '"use client";\nimport type { Copy } from "@/lib/copy";\nexport function ProvokedClient({ copy }: { copy: Pick<Copy, "calls">; t: Copy["shell"] }) { return null; }';
  const goodServer = [
    '<ProvokedClient copy={pickCopy(copy, "calls")} fallback={<p>{copy.calls.title}</p>} />',
    '<Shell copy={copy}><ProvokedClient copy={{ ...pickCopy(copy, "team"), hints: pickHints(copy, "about") }} hints={hints} /></Shell>',
  ];
  const report = (files) => {
    const out = [];
    const clientNames = new Set();
    for (const f of files.filter((x) => isClientText(x.text))) {
      for (const m of f.text.matchAll(/export (?:default )?(?:async )?function ([A-Z][A-Za-z0-9]*)|export const ([A-Z][A-Za-z0-9]*)\s*=/g)) clientNames.add(m[1] ?? m[2]);
      if (typesWholeCopy(f.text)) out.push(`${f.rel}: a client component takes the whole Copy (type its prop Pick<Copy, …> and hand it pickCopy(copy, …))`);
    }
    for (const f of files.filter((x) => !isClientText(x.text))) {
      for (const name of handedBareCatalog(f.text)) {
        if (clientNames.has(name)) out.push(`${f.rel}: hands the client component ${name} the whole catalog; hand it pickCopy(copy, …)`);
      }
      for (const name of handedEveryHint(f.text)) {
        if (clientNames.has(name)) out.push(`${f.rel}: hands the client component ${name} every hint; hand it pickHints(copy, …)`);
      }
    }
    return out;
  };
  const sampleFiles = (client, server) => [{ rel: "provoked/ProvokedClient.tsx", text: client }, ...server.map((text, i) => ({ rel: `provoked/page${i + 1}.tsx`, text }))];
  const out = [];
  // the whole rule on the samples: five reports from the bad ones (the type, and one per bad hand-over), none from the good
  const fromBad = report(sampleFiles(badClient, badServer));
  const fromGood = report(sampleFiles(goodClient, goodServer));
  if (fromBad.length !== 5 || fromGood.length !== 0) {
    out.push(`verify:copy's own check of the catalog's hand-over no longer tells its bad samples from its good ones (${fromBad.length} of 5 reported, ${fromGood.length} false)`);
  }
  const files = tsxUnder(srcDir).map((file) => ({ rel: path.relative(srcDir, file), text: readFileSync(file, "utf8") }));
  return [...out, ...report(provoked ? [...files, ...sampleFiles(badClient, badServer)] : files)];
}

const provoke = process.argv.includes("--provoke");
const languages = { en: extract("en"), nl: extract("nl") };
if (provoke) {
  languages.en.myDay.title = "My day.";
  languages.nl.shell.testData = "Welkom! De API sync is bezig";
  delete languages.nl.nav.logOut;
}
const problems = check(languages);
// The catalog stays on the server (12 November 2026): a client component's props travel to the browser with the page and
// with every click, and the whole catalog is 59 kB gzipped. So no client component takes the whole Copy (its prop is a
// Pick of the parts it reads, or its own words), and no server file hands a client component the bare catalog or every
// hint: it hands pickCopy(copy, …) and pickHints(copy, …). --provoke reads the bad samples as files of the repository
problems.push(...wholeCatalogToClient(provoke));
for (const p of problems) console.log("  " + p);
const keyCount = Object.keys(flatten(languages.en)).length;
console.log(problems.length === 0 ? `copy: PASS (${keyCount} keys, en and nl)` : `copy: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
