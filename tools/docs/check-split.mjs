/**
 * Check: the README split of 20 October 2026 moved every line of the old README.md verbatim into
 * README.md plus the files of its Documentation map. Node, no dependencies; run from the repo root.
 *
 *   node tools/docs/check-split.mjs               expect PASS, exit 0
 *   node tools/docs/check-split.mjs --base <rev>  the old README from <rev> instead of the merge base
 *                                                 with origin/main (after the split has merged)
 *   node tools/docs/check-split.mjs --provoke     drops one moved line and doubles another, in memory;
 *                                                 expect FAIL naming both, exit 1
 *
 * Every non-empty line of the old README must appear, as an exact line, as often in the new files as
 * it did in the old one. `---` and table header and separator rows may repeat. The old lines changed on
 * purpose are listed in tools/docs/split-edits.json and count as covered when their new text is in place.
 */
import { execSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const PROVOKE = process.argv.includes("--provoke");
const baseAt = process.argv.indexOf("--base");
const README_MAX_BYTES = 80_000;

const git = (cmd) => execSync(`git ${cmd}`, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
const base = baseAt > 0 ? process.argv[baseAt + 1] : git("merge-base HEAD origin/main").trim();
const oldText = git(`show ${base}:README.md`);
const oldLines = oldText.split("\n");

const mdIn = (dir) => readdirSync(dir, { recursive: true }).filter((f) => f.endsWith(".md")).map((f) => join(dir, f)).sort();
const NEW_FILES = ["README.md", "CHANGELOG.md", "docs/decisions.md", "docs/open-decisions.md",
  ...mdIn("docs/product"), ...mdIn("docs/architecture")];
const files = NEW_FILES.map((path) => ({ path, lines: readFileSync(path, "utf8").split("\n") }));
const edits = JSON.parse(readFileSync("tools/docs/split-edits.json", "utf8"));

let named = [];
if (PROVOKE) {
  const decisions = files.find((f) => f.path === "docs/decisions.md");
  const at = decisions.lines.findIndex((l) => l.startsWith("| 3 Oct 2026 |"));
  const [dropped] = decisions.lines.splice(at, 1);
  const kpis = files.find((f) => f.path === "docs/product/kpis.md");
  const doubled = kpis.lines.find((l) => l.startsWith("### 1. "));
  files.find((f) => f.path === "docs/product/features.md").lines.push(doubled);
  named = [`missing: ${dropped.slice(0, 40)}`, `duplicated: ${doubled.slice(0, 40)}`];
  console.log(`check-split: provoked, one Decision log row dropped and "${doubled}" doubled into features.md`);
}

const blank = (l) => l.trim() === "";
const SEPARATOR = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/;
// `---`, table separator rows and the row above each separator (a table's header) may repeat.
const repeatable = new Set(["---"]);
for (const lines of [oldLines, ...files.map((f) => f.lines)]) {
  lines.forEach((l, i) => {
    if (!SEPARATOR.test(l)) return;
    repeatable.add(l);
    if (i > 0 && !blank(lines[i - 1])) repeatable.add(lines[i - 1]);
  });
}

const problems = [];
const count = (map, key, value) => map.set(key, [...(map.get(key) ?? []), value]);
const oldAt = new Map();
oldLines.forEach((l, i) => { if (!blank(l)) count(oldAt, l, i + 1); });
const newAt = new Map();
for (const f of files) f.lines.forEach((l, i) => { if (!blank(l)) count(newAt, l, `${f.path}:${i + 1}`); });

const editedOld = new Set();
const editedNew = new Set();
for (const e of edits) {
  if ((oldAt.get(e.old) ?? []).length !== 1) problems.push(`edit: the old line of ${e.section} is not in the old README exactly once`);
  if (!(newAt.get(e.new) ?? []).some((at) => at.startsWith(`${e.file}:`))) problems.push(`edit: the new line of ${e.section} is not in ${e.file}`);
  editedOld.add(e.old);
  editedNew.add(e.new);
}

let coveredOnce = 0;
let repeats = 0;
let intentional = 0;
const missing = [];
const duplicated = [];
for (const [line, at] of oldAt) {
  const found = newAt.get(line) ?? [];
  if (editedOld.has(line)) intentional += at.length;
  else if (found.length === at.length) coveredOnce += at.length;
  // `---` separates sections, so it follows the new layout; repeatable rows may only appear more often.
  else if (repeatable.has(line) && (found.length > at.length || (line === "---" && found.length > 0))) repeats += at.length;
  else if (found.length > at.length) {
    coveredOnce += at.length;
    duplicated.push({ line, at, found });
  } else {
    coveredOnce += found.length;
    missing.push({ line, at, short: at.length - found.length });
  }
}
const newLines = [];
for (const f of files) {
  f.lines.forEach((line, i) => {
    if (!blank(line) && !oldAt.has(line) && !editedNew.has(line)) newLines.push({ line, a: `${f.path}:${i + 1}` });
  });
}

// Every ## and ### heading of the old README has a Documentation map row naming the file that holds it.
const readme = files.find((f) => f.path === "README.md").lines;
const mapStart = readme.indexOf("## Documentation map");
const mapRows = readme.slice(mapStart, readme.indexOf("---", mapStart)).filter((l) => l.startsWith("| "));
const headings = oldLines.filter((l) => /^#{2,3} /.test(l));
for (const h of headings) {
  const text = h.replace(/^#+ /, "");
  const row = mapRows.find((r) => r.startsWith(`| ${text} |`) || r.startsWith(`| **${text}** `));
  if (!row) { problems.push(`documentation map: no row for "${text}"`); continue; }
  const path = /\[([^\]]+)\]/.exec(row)?.[1] ?? "README.md";
  const holder = files.find((f) => f.path === path);
  if (!holder?.lines.includes(h)) problems.push(`documentation map: "${text}" is not in ${path}`);
}

const bytes = (path) => statSync(path).size;
if (bytes("README.md") >= README_MAX_BYTES) problems.push(`README.md is ${bytes("README.md")} bytes, not under 80 KB`);
for (const m of missing) problems.push(`missing: ${m.line.slice(0, 80)} (old line ${m.at.join(", ")}; ${m.short} of ${m.at.length} not found)`);
for (const d of duplicated) problems.push(`duplicated: ${d.line.slice(0, 80)} (old line ${d.at.join(", ")}; in ${d.found.join(", ")})`);

const oldCount = [...oldAt.values()].reduce((n, at) => n + at.length, 0);
const kb = (n) => `${(n / 1000).toFixed(1)} KB`;
console.log(`check-split: old README.md at ${base.slice(0, 12)}, ${kb(Buffer.byteLength(oldText))}`);
console.log(`  old lines:          ${oldCount} non-empty`);
console.log(`  covered once:       ${coveredOnce}`);
console.log(`  allowed repeats:    ${repeats} (---, table header and separator rows found more often)`);
console.log(`  intentional edits:  ${intentional} (tools/docs/split-edits.json)`);
console.log(`  missing:            ${missing.reduce((n, m) => n + m.short, 0)}`);
console.log(`  duplicated:         ${duplicated.length}`);
console.log(`  map headings:       ${headings.length} (every ## and ### heading of the old README)`);
console.log(`  new lines:          ${newLines.length}`);
for (const { line, a } of newLines) console.log(`    ${a.padEnd(48)} ${line.slice(0, 80)}`);
console.log("  sizes:");
for (const f of files) console.log(`    ${f.path.padEnd(48)} ${kb(bytes(f.path)).padStart(9)}`);
for (const p of problems) console.log(`  ${p}`);

const missed = named.filter((n) => !problems.some((p) => p.startsWith(n)));
if (missed.length) {
  // A provocation the check does not name is one it cannot fail on.
  console.log(`check-split: provoked, but not caught: ${missed.join("; ")}`);
  process.exit(0);
}
console.log(problems.length === 0 ? "check-split: PASS" : `check-split: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
