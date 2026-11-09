/**
 * Unit test: tools/check-records.mjs on the synthetic fixture tools/fixtures/check-records/ (a clean and a dirty
 * rerun output; every address on a domain reserved for examples, example.com, .invalid or .test) and on small files
 * written to a temporary folder. No database, no real data.
 *
 *   node --test tools/check-records.test.mjs
 */
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { allowedDomain, checkPaths, findProblems, masked } from "./check-records.mjs";

const TOOL = fileURLToPath(new URL("./check-records.mjs", import.meta.url));
const FIXTURES = fileURLToPath(new URL("./fixtures/check-records/", import.meta.url));
const LOGIN = "operator.login@acme.test";
const root = mkdtempSync(join(tmpdir(), "check-records-"));
after(() => rmSync(root, { recursive: true, force: true }));

/** The tool as a command: exit code and printed lines */
function run(args, env = {}) {
  const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: "utf8", env: { ...process.env, CMA_OPERATOR_LOGIN: "", ...env } });
  return { status: r.status, out: r.stdout.trim().split("\n").filter(Boolean), err: r.stderr.trim() };
}

test("the domains that belong to no person are allowed, every other is not", () => {
  for (const d of ["example.com", "mail.example.com", "system.invalid", "example.invalid", "p4a-cma-dev.iam",
    "developer.iam.gserviceaccount.com"]) assert.equal(allowedDomain(d), true, d);
  for (const d of ["acme.test", "pulse4all.example", "example.org", "notexample.com", "gmail.com"]) assert.equal(allowedDomain(d), false, d);
});

test("a finding shows the address with its local part cut to one letter", () => {
  assert.equal(masked("jane.doe@acme.test"), "j…@acme.test");
});

test("the clean fixture passes, also with the operator's login given", () => {
  const r = run(["--login", LOGIN, join(FIXTURES, "clean")]);
  assert.equal(r.status, 0);
  assert.deepEqual(r.out, ["records clean: 1 files"]);
});

test("the dirty fixture fails with file and line for each address and each line holding the login", () => {
  const r = run(["--login", LOGIN, join(FIXTURES, "dirty")]);
  assert.equal(r.status, 1);
  const findings = r.out.filter((l) => !l.startsWith("records not clean"));
  assert.deepEqual(findings.map((l) => l.replace(/^.*07-rerun\.txt:/, "")), [
    "3: address outside example.com: o…@acme.test",
    "3: the operator's login: o…@acme.test",
    "9: address outside example.com: J…@Acme.Test",
    "12: the operator's login: o…@acme.test",
  ]);
  assert.match(r.out.at(-1), /^records not clean: 4 finding\(s\) in 1 of 1 files/);
  assert.ok(!r.out.join("\n").includes("operator.login@") && !r.out.join("\n").includes("Jane.Doe@"), "no full address printed");
});

test("without a login the address rule still fails the dirty fixture; the URL-encoded login alone is then not seen", () => {
  const r = run([join(FIXTURES, "dirty")]);
  assert.equal(r.status, 1);
  assert.equal(r.out.filter((l) => l.includes("the operator's login")).length, 0);
  assert.equal(r.out.filter((l) => l.includes("address outside example.com")).length, 2);
});

test("CMA_OPERATOR_LOGIN stands in for --login", () => {
  const r = run([join(FIXTURES, "dirty")], { CMA_OPERATOR_LOGIN: LOGIN });
  assert.equal(r.out.filter((l) => l.includes("the operator's login")).length, 2);
});

test("a folder is walked, a binary file is skipped and not counted", () => {
  const dir = join(root, "walk");
  mkdirSync(join(dir, "sub"), { recursive: true });
  writeFileSync(join(dir, "a.txt"), "ok: agent.one@example.com\n");
  writeFileSync(join(dir, "sub", "b.md"), "ok: written down from the operator's report\n");
  writeFileSync(join(dir, "c.png"), Buffer.from([0x89, 0x50, 0x00, 0x40, 0x61, 0x40, 0x62, 0x2e, 0x63, 0x6f]));
  const r = run([dir]);
  assert.deepEqual({ status: r.status, out: r.out }, { status: 0, out: ["records clean: 2 files"] });
  assert.equal(checkPaths([dir]).files, 2);
});

test("findProblems finds several addresses on one line and reports each", () => {
  const p = findProblems("a@one.test, b@example.com, c@two.test\nnothing here", {});
  assert.deepEqual(p.map((x) => `${x.line} ${x.shown}`), ["1 a…@one.test", "1 c…@two.test"]);
});

test("no path and a missing path are usage errors (exit 2)", () => {
  assert.equal(run([]).status, 2);
  const r = run([join(root, "nowhere")]);
  assert.equal(r.status, 2);
  assert.match(r.err, /no such path/);
});
