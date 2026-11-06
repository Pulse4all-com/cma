/**
 * Verifier: every function a db/ script redefines names the definition it is based on (CLAUDE.md, Database (db/);
 * Decision log, 6 November 2026, addition 0009b). No database: it reads the scripts' text only.
 *
 *   node tools/verify-function-bases.mjs             every check must PASS
 *   node tools/verify-function-bases.mjs --provoke   every check must FAIL
 * (from web/: npm run verify:function-bases)
 *
 * The rule: a `create [or replace] function` (or procedure) in a script numbered FROM (152) or later carries, on the
 * line directly above it,
 *   -- based on: <file>.sql
 * when it redefines a function, naming the script that holds the latest earlier definition (the same script when it
 * was defined earlier in it). It redefines one when
 *   - the same schema, name and argument types were defined earlier in run order (the scripts by their number), whether
 *     or not the function was dropped in between; the base is that signature's latest definition; or
 *   - the same script drops a signature of the same schema and name before it and creates it with other argument types
 *     (a rebuild with a changed signature); the base is the dropped signature's latest definition (for a drop without
 *     argument types, the latest definition of any signature of that name).
 * Scripts before FROM are exempt. A new function may carry the line too (a rewrite under a new name); its file must
 * then exist and come no later in run order. A new overload beside an existing one, without a drop, needs no line.
 * pg_temp functions (the verify scripts' own) are no definitions. Comments, quoted strings and dollar-quoted bodies are
 * skipped, so a `create function` inside a DO block's or a function's body, or in a comment, is no definition. Argument
 * types are compared after the usual spellings are made one (timestamptz and timestamp with time zone, int and integer,
 * float and double precision, a precision such as (3) dropped, ...); names, defaults and OUT arguments are not part of a
 * function's identity, as in PostgreSQL. An unqualified name is taken as cma's (the database's search path).
 * A drop is followed at the top level and inside a DO block's body (the repository's conditional drops before a rebuild).
 * Not followed: a function created by EXECUTE (inside a DO block it is masked out), a drop by EXECUTE, alter function
 * ... rename to or set schema. The line proves which text the author named, not that the body started from it: the verify that compares the
 * new definition with the right earlier one stays the real check.
 *
 * Checks: the repository's db/ (every redefinition from FROM on, each named); synthetic scripts for each way the rule
 * can be broken (no line, an earlier but not the latest definition named, a file that does not define it, a line not
 * directly above, a later file, a drop and create of the same or of another signature without the line) and for what
 * it must not flag (an overload, another spelling of the same types, a script before FROM, text in a comment or a body,
 * the same script, a rebuild that names its base, pg_temp). Provoked, the repository is
 * checked with its first redefinition's line removed and again with that line naming an earlier, not the latest,
 * definition (as 0008zr's rebuild of cma.calls_of from 76 instead of 100), and every synthetic check expects the
 * opposite: each check must FAIL.
 */
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const FROM = 152;
const DB = join(dirname(fileURLToPath(import.meta.url)), "..", "db");
const PROVOKE = process.argv.includes("--provoke");

/** The script's number (its run order), or null for a name without one */
export function scriptNumber(file) {
  const m = /^(\d+)_.*\.sql$/.exec(file);
  return m ? Number(m[1]) : null;
}

/**
 * The text with comments, single-quoted strings and dollar-quoted bodies blanked (newlines kept, so offsets and lines
 * hold). With keepDo, a DO block's body stays readable (itself masked the same way), so a drop written in it is seen
 */
export function mask(text, keepDo = false) {
  const out = text.split("");
  const blank = (from, to) => { for (let i = from; i < to; i++) if (out[i] !== "\n") out[i] = " "; };
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const next = text[i + 1];
    if (c === "-" && next === "-") {
      let j = text.indexOf("\n", i);
      if (j < 0) j = text.length;
      blank(i, j); i = j;
    } else if (c === "/" && next === "*") {
      let depth = 1; let j = i + 2;
      while (j < text.length && depth > 0) {
        if (text[j] === "/" && text[j + 1] === "*") { depth++; j += 2; }
        else if (text[j] === "*" && text[j + 1] === "/") { depth--; j += 2; }
        else j++;
      }
      blank(i, j); i = j;
    } else if (c === "'") {
      const escapes = i > 0 && /[eE]/.test(text[i - 1]) && !/[A-Za-z0-9_]/.test(text[i - 2] ?? "");
      let j = i + 1;
      while (j < text.length) {
        if (escapes && text[j] === "\\") { j += 2; continue; }
        if (text[j] === "'") { if (text[j + 1] === "'") { j += 2; continue; } break; }
        j++;
      }
      blank(i + 1, j); i = j + 1;
    } else if (c === '"') {
      const j = text.indexOf('"', i + 1);
      i = j < 0 ? text.length : j + 1;
    } else if (c === "$" && !/[A-Za-z0-9_]/.test(text[i - 1] ?? "")) {
      const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(text.slice(i, i + 80));
      if (!m) { i++; continue; }
      const tag = m[0];
      const end = text.indexOf(tag, i + tag.length);
      const j = end < 0 ? text.length : end + tag.length;
      if (keepDo && /(?:^|[^A-Za-z0-9_$])do(?:\s+language\s+[A-Za-z_]+)?\s*$/i.test(text.slice(Math.max(0, i - 40), i))) {
        const inner = mask(text.slice(i + tag.length, end < 0 ? text.length : end), true);
        for (let k = 0; k < inner.length; k++) out[i + tag.length + k] = inner[k];
      } else blank(i + tag.length, end < 0 ? text.length : end);
      i = j;
    } else i++;
  }
  return out.join("");
}

/** Splits at the commas outside parentheses */
function splitTop(s) {
  const parts = []; let depth = 0; let cur = "";
  for (const ch of s) {
    if (ch === "(" || ch === "[") depth++;
    if (ch === ")" || ch === "]") depth--;
    if (ch === "," && depth === 0) { parts.push(cur); cur = ""; } else cur += ch;
  }
  if (cur.trim() !== "") parts.push(cur);
  return parts;
}

const MULTIWORD = ["timestamp with", "timestamp without", "time with", "time without", "double precision", "character varying", "bit varying"];
const ALIASES = new Map(Object.entries({
  timestamptz: "timestamp with time zone", timestamp: "timestamp without time zone", "timestamp without time zone": "timestamp without time zone",
  timetz: "time with time zone", time: "time without time zone", int: "integer", int4: "integer", int8: "bigint", int2: "smallint",
  bool: "boolean", varchar: "character varying", char: "character", float8: "double precision", float4: "real", decimal: "numeric",
  float: "double precision",
}));

/** One argument's type in one spelling, or null for an OUT argument (not part of the identity) */
export function argType(raw) {
  let a = raw.replace(/\s+/g, " ").trim();
  a = a.replace(/(\s+default\b|\s*=).*$/i, "").trim();
  const mode = /^(in|out|inout|variadic)\s+/i.exec(a);
  if (mode) {
    if (mode[1].toLowerCase() === "out") return null;
    a = a.slice(mode[0].length);
  }
  a = a.replace(/\bfloat\s*\(\s*([1-9]|1\d|2[0-4])\s*\)/i, "real").replace(/\s*\([\d\s,]*\)/g, "");
  const lower = a.toLowerCase();
  if (/\s/.test(a) && !MULTIWORD.some((p) => lower.startsWith(p))) a = a.slice(a.indexOf(" ") + 1);
  let t = a.toLowerCase().replace(/"/g, "").replace(/^pg_catalog\./, "").replace(/\s+/g, " ").trim();
  let dims = "";
  const arr = /(\s*\[\s*\d*\s*\])+$/.exec(t);
  if (arr) { dims = "[]".repeat((arr[0].match(/\[/g) ?? []).length); t = t.slice(0, -arr[0].length).trim(); }
  return (ALIASES.get(t) ?? t) + dims;
}

function identName(s) {
  return s.split(".").map((p) => { p = p.trim(); return p.startsWith('"') ? p.slice(1, -1) : p.toLowerCase(); });
}

/** A function's identity (schema.name(types)) from its written name and argument list; null for pg_temp */
function identity(written, args) {
  const parts = identName(written);
  const [schema, name] = parts.length === 2 ? parts : ["cma", parts[0]];
  if (schema === "pg_temp") return null;
  return { name: `${schema}.${name}`, key: args === null ? null : `${schema}.${name}(${splitTop(args).map(argType).filter((t) => t !== null).join(",")})` };
}

const NAME = '(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\\s*\\.\\s*(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*))?';

/** The signatures one script drops (drop function|procedure [if exists] a(...), b, ...), DO blocks included, with their offsets */
export function drops(text, masked = mask(text, true)) {
  const found = [];
  const re = /\bdrop\s+(?:function|procedure)\s+(?:if\s+exists\s+)?/gi;
  let m;
  while ((m = re.exec(masked)) !== null) {
    let j = re.lastIndex;
    for (;;) {
      const nm = new RegExp(`^\\s*(${NAME})\\s*`).exec(masked.slice(j));
      if (!nm) break;
      j += nm[0].length;
      let args = null;
      if (masked[j] === "(") {
        let depth = 1; let k = j + 1;
        while (k < masked.length && depth > 0) { if (masked[k] === "(") depth++; if (masked[k] === ")") depth--; k++; }
        args = masked.slice(j + 1, k - 1); j = k;
      }
      const id = identity(nm[1], args);
      if (id) found.push({ at: m.index, ...id });
      const comma = /^\s*,/.exec(masked.slice(j));
      if (!comma) break;
      j += comma[0].length;
    }
  }
  return found;
}

/** The function definitions of one script: identity, the line of `create`, and the line directly above it */
export function definitions(file, text) {
  const masked = mask(text);
  const lines = text.split("\n");
  const re = /\bcreate\s+(?:or\s+replace\s+)?(?:function|procedure)\s+((?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*))?)\s*\(/gi;
  const found = [];
  let m;
  while ((m = re.exec(masked)) !== null) {
    let depth = 1; let j = re.lastIndex;
    while (j < masked.length && depth > 0) { if (masked[j] === "(") depth++; if (masked[j] === ")") depth--; j++; }
    const id = identity(m[1], masked.slice(re.lastIndex, j - 1));
    if (!id) continue;
    const line = masked.slice(0, m.index).split("\n").length;
    found.push({ file, line, at: m.index, name: id.name, key: id.key, above: line >= 2 ? lines[line - 2] : "" });
  }
  return found;
}

const BASED_ON = /^\s*--\s*based on:\s*(\S+)\s*$/i;

/**
 * Checks a set of scripts ([{ file, text }], any order): the problems ({ kind: missing | wrong | unknown, text }) of
 * every definition from FROM on, and the redefinitions checked
 */
export function check(scripts, from = FROM) {
  const ordered = scripts
    .filter((s) => scriptNumber(s.file) !== null)
    .sort((a, b) => scriptNumber(a.file) - scriptNumber(b.file) || (a.file < b.file ? -1 : 1));
  const order = new Map(ordered.map((s, i) => [s.file, i]));
  const latest = new Map();
  const latestByName = new Map();
  const problems = [];
  const checked = [];
  for (const s of ordered) {
    const dropped = drops(s.text);
    for (const d of definitions(s.file, s.text)) {
      let prev = latest.get(d.key);
      let how = "";
      if (!prev) {
        // a rebuild with another signature: this script dropped a signature of the same name before this create
        const drop = dropped.filter((x) => x.at < d.at && x.name === d.name && x.key !== d.key).at(-1);
        if (drop) {
          prev = drop.key === null ? latestByName.get(d.name) : latest.get(drop.key);
          if (prev) how = ` (a rebuild of ${prev.key}, dropped above)`;
        }
      }
      if (scriptNumber(s.file) >= from) {
        const named = BASED_ON.exec(d.above)?.[1] ?? null;
        const where = `${d.file}:${d.line} ${d.key}`;
        if (prev) {
          checked.push({ where, base: prev.file });
          if (named === null) problems.push({ kind: "missing", text: `${where} redefines a function${how} without "-- based on: ${prev.file}" directly above it` });
          else if (named !== prev.file) problems.push({ kind: "wrong", text: `${where}${how} names ${named}, but its latest earlier definition is in ${prev.file} (line ${prev.line})` });
        } else if (named !== null && !(order.has(named) && order.get(named) <= order.get(s.file))) {
          problems.push({ kind: "unknown", text: `${where} names ${named}, which is no db/ script before it` });
        }
      }
      latest.set(d.key, d);
      latestByName.set(d.name, d);
    }
  }
  return { problems, checked };
}

/** The repository's db/ scripts */
export function repositoryScripts() {
  return readdirSync(DB).filter((f) => f.endsWith(".sql")).map((file) => ({ file, text: readFileSync(join(DB, file), "utf8") }));
}

// ---------------------------------------------------------------------------------------------------------------
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let n = 0;
  let passed = 0;
  const expect = (name, actual, expected, provoked) => {
    const want = PROVOKE ? provoked : expected;
    const ok = JSON.stringify(actual) === JSON.stringify(want);
    n += 1;
    if (ok) passed += 1;
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : `\n      got      ${JSON.stringify(actual)}\n      expected ${JSON.stringify(want)}`}`);
  };

  // The repository: every redefinition from FROM on names its latest earlier definition. Provoked: the first
  // redefinition's line removed, then naming the earlier definition before the latest (or, without one, a later script)
  const repo = repositoryScripts();
  const base = check(repo);
  for (const c of base.checked) console.log(`      ${c.where}  based on ${c.base}`);
  let missing = repo;
  let wrong = repo;
  if (PROVOKE && base.checked.length > 0) {
    const first = base.checked[0];
    const file = first.where.split(":")[0];
    const line = Number(first.where.split(":")[1].split(" ")[0]);
    const earlier = check(repo, 0).checked.filter((c) => c.where.split(" ")[1] === first.where.split(" ")[1] && c.base !== first.base).at(-1)?.base
      ?? "999_none.sql";
    const edit = (fn) => repo.map((s) => (s.file !== file ? s : { file, text: s.text.split("\n").map((l, i) => (i === line - 2 ? fn(l) : l)).join("\n") }));
    missing = edit(() => "");
    wrong = edit(() => `-- based on: ${earlier}`);
  }
  expect(`db/: every redefinition from ${FROM} on carries "-- based on: <file>.sql" directly above it (${base.checked.length} checked)`,
    check(missing).problems.filter((p) => p.kind === "missing").map((p) => p.text), [], []);
  expect(`db/: each names the script of the function's latest earlier definition`,
    check(wrong).problems.filter((p) => p.kind !== "missing").map((p) => p.text), [], []);
  if (base.checked.length === 0 && PROVOKE) {
    expect("db/: nothing to provoke (no redefinition from FROM on)", true, true, false);
  }

  // Synthetic scripts
  const fn = (name, args, body = "select 1") => `create or replace function ${name}(${args})\nreturns integer\nlanguage sql\nas $$\n  ${body}\n$$;\n`;
  const based = (file) => `-- based on: ${file}\n`;
  const S = (...pairs) => pairs.map(([file, text]) => ({ file, text }));
  const one = "10_a.sql"; const two = "20_b.sql"; const late = `${FROM}_c.sql`; const later = `${FROM + 1}_d.sql`;
  const res = (scripts) => check(scripts).problems.length;

  expect("a redefinition without the line is reported", res(S([one, fn("cma.f", "p uuid")], [late, fn("cma.f", "p uuid")])), 1, 0);
  expect("an earlier but not the latest definition named is reported (0008zr's case)",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p uuid")], [late, based(one) + fn("cma.f", "p uuid")])), 1, 0);
  expect("a script that does not define the function named is reported",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.g", "p uuid")], [late, based(two) + fn("cma.f", "p uuid")])), 1, 0);
  expect("the latest earlier definition named passes",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p uuid")], [late, based(two) + fn("cma.f", "p uuid")])), 0, 1);
  expect("a line not directly above (a comment between) is reported",
    res(S([one, fn("cma.f", "p uuid")], [late, based(one) + "-- what it does\n" + fn("cma.f", "p uuid")])), 1, 0);
  expect("a line naming a later script on a new function is reported",
    res(S([late, based(later) + fn("cma.n", "p uuid")], [later, fn("cma.m", "p uuid")])), 1, 0);
  expect("a new function under a new name may name its source",
    res(S([one, fn("cma.f", "p uuid")], [late, based(one) + fn("cma.f_compute", "p uuid")])), 0, 1);
  expect("an overload (other argument types) is a new function: no line needed",
    res(S([one, fn("cma.f", "p uuid")], [late, fn("cma.f", "p uuid, q text")])), 0, 1);
  expect("other spellings of the same types, argument names, defaults and OUT arguments are the same function",
    res(S([one, fn("cma.f", "p_a uuid, p_b timestamptz, p_c int default 3, out x text")],
          [late, fn('"cma"."f"', "uuid, timestamp with time zone, in p_c integer = 4")])), 1, 0);
  expect("a script before FROM is exempt", res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p uuid")])), 0, 1);
  expect("a create function in a comment, a string or a body is no definition",
    res(S([one, fn("cma.f", "p uuid")],
          [late, "-- create or replace function cma.f(p uuid)\nselect 'create function cma.f(p uuid)';\n" +
                 "do $$ begin execute 'x'; end $$;\n" + fn("cma.g", "p uuid", "select 'create or replace function cma.f(p uuid)'")])), 0, 1);
  expect("a redefinition later in the same script names that script",
    res(S([late, fn("cma.f", "p uuid") + "\n" + based(late) + fn("cma.f", "p uuid")])), 0, 1);
  expect("a drop and create of the same signature is a redefinition",
    res(S([one, fn("cma.f", "p uuid")], [late, "drop function if exists cma.f(uuid);\n" + fn("cma.f", "p uuid")])), 1, 0);
  expect("a rebuild with another signature (a drop, then a create) without the line is reported",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p uuid")],
          [late, "drop function if exists cma.g(text), cma.f(uuid);\n" + fn("cma.f", "p uuid, q integer")])), 1, 0);
  expect("a rebuild with another signature naming the dropped signature's latest definition passes",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p uuid")],
          [late, "drop function cma.f(uuid);\n" + based(two) + fn("cma.f", "p uuid, q integer")])), 0, 1);
  expect("a drop inside a DO block, then a create with other argument types, is a rebuild",
    res(S([one, fn("cma.f", "p uuid")],
          [late, "do $$\nbegin\n  if to_regprocedure('cma.f(uuid)') is not null then\n    drop function cma.f(uuid);\n  end if;\nend\n$$;\n" +
                 fn("cma.f", "p uuid, q integer")])), 1, 0);
  expect("a drop without argument types, then a create, names the name's latest definition",
    res(S([one, fn("cma.f", "p uuid")], [two, fn("cma.f", "p text")],
          [late, "drop function cma.f;\n" + based(two) + fn("cma.f", "p uuid, q integer")])), 0, 1);
  expect("a precision and float spell the same types",
    res(S([one, fn("cma.f", "p timestamp(3) with time zone, q float, r float(8), s int=3")],
          [late, fn("cma.f", "timestamptz, double precision, real, integer")])), 1, 0);
  expect("pg_temp functions are no definitions", res(S([one, fn("pg_temp.f", "p uuid")], [late, fn("pg_temp.f", "p uuid")])), 0, 1);

  if (PROVOKE) {
    const allFailed = passed === 0;
    console.log(`\n${allFailed ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
    process.exit(allFailed ? 0 : 1);
  }
  console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(passed === n ? 0 : 1);
}
