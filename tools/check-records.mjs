#!/usr/bin/env node
/**
 * Records check: no real person's address in raw outputs before they are committed or pushed (CLAUDE.md, Git and release;
 * docs/RUNBOOK.md, Setup step 8; Decision log, 9 Nov 2026, verify output from prod). Plain Node, no dependencies.
 *
 *   node tools/check-records.mjs [--login <address>] <dir or file>...
 *   node tools/check-records.mjs --login "$(gcloud config get-value account 2>/dev/null)" records/0009g-prod-2026-11-09
 *
 * Names file and line of
 *   - every email address outside the domains that belong to no person: example.com (the dev seed and the fixtures, and
 *     its subdomains), the reserved top-level domain .invalid (the system users, scheduler@system.invalid and
 *     ingest@system.invalid, and the verify fixtures) and Google service accounts (*.iam, *.iam.gserviceaccount.com);
 *   - every line holding the operator's login: --login, else the environment variable CMA_OPERATOR_LOGIN, in any case and
 *     also URL-encoded (%40), so a login that is no address in the output's form is caught too. Without either, the
 *     address rule above still catches a login that is an address.
 * The finding prints the address with its local part cut to one letter (m…@domain), so the output itself is safe to share.
 * Text files only: a file with a NUL byte in its first 8 KB is skipped as binary and not counted.
 *
 * Exit 0 and "records clean: <n> files"; exit 1 with one line per finding and "records not clean: ..."; exit 2 on a
 * usage error (no path given, a path that does not exist). Unit test: node --test tools/check-records.test.mjs
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;

/** True for a domain that belongs to no person (see the header) */
export function allowedDomain(domain) {
  const d = domain.toLowerCase();
  return d === "example.com" || d.endsWith(".example.com")
    || d === "invalid" || d.endsWith(".invalid")
    || d.endsWith(".iam") || d.endsWith(".iam.gserviceaccount.com");
}

/** m…@domain: the local part cut to its first letter */
export function masked(address) {
  const at = address.lastIndexOf("@");
  return `${address.slice(0, 1)}…${address.slice(at)}`;
}

/** The findings of one text as [{ line, kind, shown }] */
export function findProblems(text, { login = "" } = {}) {
  const out = [];
  const needle = login.trim().toLowerCase();
  const needles = needle ? [needle, needle.replace("@", "%40")] : [];
  text.split(/\r?\n/).forEach((lineText, i) => {
    for (const m of lineText.matchAll(EMAIL)) {
      const domain = m[0].slice(m[0].lastIndexOf("@") + 1);
      if (!allowedDomain(domain)) out.push({ line: i + 1, kind: "address outside example.com", shown: masked(m[0]) });
    }
    const lower = lineText.toLowerCase();
    if (needles.some((n) => lower.includes(n))) out.push({ line: i + 1, kind: "the operator's login", shown: masked(needle) });
  });
  return out;
}

/** Every file under the paths, sorted, directories followed */
function filesOf(path) {
  if (!statSync(path).isDirectory()) return [path];
  return readdirSync(path).sort().flatMap((name) => filesOf(join(path, name)));
}

function isBinary(buffer) {
  return buffer.subarray(0, 8192).includes(0);
}

/** Checks the paths: { files, problems: [{ file, line, kind, shown }] } */
export function checkPaths(paths, opts = {}) {
  let files = 0;
  const problems = [];
  for (const file of paths.flatMap(filesOf)) {
    const buffer = readFileSync(file);
    if (isBinary(buffer)) continue;
    files++;
    for (const p of findProblems(buffer.toString("utf8"), opts)) problems.push({ file, ...p });
  }
  return { files, problems };
}

function main(argv) {
  const paths = [];
  let login = process.env.CMA_OPERATOR_LOGIN ?? "";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--login") login = argv[++i] ?? "";
    else paths.push(argv[i]);
  }
  if (paths.length === 0) {
    console.error("usage: node tools/check-records.mjs [--login <address>] <dir or file>...");
    return 2;
  }
  const missing = paths.filter((p) => !existsSync(p));
  if (missing.length) {
    console.error(`check-records: no such path: ${missing.join(", ")}`);
    return 2;
  }
  const { files, problems } = checkPaths(paths, { login });
  for (const p of problems) console.log(`${relative(process.cwd(), p.file) || p.file}:${p.line}: ${p.kind}: ${p.shown}`);
  if (problems.length) {
    const inFiles = new Set(problems.map((p) => p.file)).size;
    console.log(`records not clean: ${problems.length} finding(s) in ${inFiles} of ${files} files; mask them (or leave the rows out with one line saying why) before any commit`);
    return 1;
  }
  console.log(`records clean: ${files} files`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) process.exit(main(process.argv.slice(2)));
