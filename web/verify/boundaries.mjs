/**
 * Verifier: the module boundaries of web/src (README, Code: screens import data only through @/lib/data and
 * identity only through @/lib/auth/identity; the pure libraries have no runtime imports; the proxy drops IAP's
 * headers after verification), without a browser, a server or a database. The IT audit of 17 October 2026.
 *
 *   node verify/boundaries.mjs             every rule must hold, exit 0
 *   node verify/boundaries.mjs --provoke   adds files that break every rule: must FAIL, exit 1
 *
 * Rules (import statements only; type-only imports ignored):
 *   R1 src/app/** and src/components/** never import @/lib/data/postgres, @/lib/data/mock, @/lib/db/*, pg
 *      or server-only: data comes from "@/lib/data" alone (the error contract lives in @/lib/data/errors).
 *   R2 src/app/** and src/components/** never import @/lib/auth/iap: identity comes from
 *      "@/lib/auth/identity" (and the pure "@/lib/auth/preview" for the cookie's constants).
 *   R3 the pure libraries import nothing at runtime outside their own set, and another pure library only as
 *      "./name.ts" (Decision log, 7 October 2026: Node's type stripping resolves no "@/lib" alias).
 *   R4 src/lib/api/*.ts other than respond.ts import only respond, server-only, "@/lib/reports",
 *      "@/lib/sources", "@/lib/email" (addition 0008t), "@/lib/first-orders" (0008u), "@/lib/attempts" (0008y), "@/lib/funnel"
 *      (0008zb) and types: they validate, they do not read.
 *   R5 src/lib/data/mock.ts imports nothing from @/lib/db/*: the mock must not load the database driver.
 *   R6 no "use server" anywhere: every write goes through a route with the one CSRF guard (respond.ts).
 *   R7 src/proxy.ts deletes IAP's three headers before it passes a request on (the names of IAP_HEADERS).
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("../src/", import.meta.url).pathname;
const PURE = ["csv", "dashboard", "team", "roster", "live", "reports", "messages", "configuration", "follow-up",
  "invitations", "sources", "period", "time", "nav", "alertRules", "corrections", "logout", "origin", "health", "email", "first-orders", "callbacks", "attempts", "funnel", "metrics", "reviews"];

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(ts|tsx)$/.test(name)) out.push(p);
  }
  return out;
}

/** Runtime imports of a source as [{ from, line }]; `import type` and `import { type A }` left out */
export function runtimeImports(source) {
  const out = [];
  source.split("\n").forEach((text, i) => {
    const m = text.match(/^import\s+(?!type\s)(?:[^"']*?\s+from\s+)?["']([^"']+)["']/);
    if (!m) return;
    const names = text.match(/^import\s+\{([^}]*)\}/)?.[1];
    if (names !== undefined && names.split(",").every((n) => /^\s*type\s/.test(n))) return;
    out.push({ from: m[1], line: i + 1 });
  });
  return out;
}

export function check(files) {
  const problems = [];
  for (const [path, source] of Object.entries(files)) {
    const screen = /^(app|components)\//.test(path);
    const pureName = path.match(/^lib\/([A-Za-z-]+)\.ts$/)?.[1];
    const isPure = pureName !== undefined && PURE.includes(pureName);
    const isApi = /^lib\/api\/[A-Za-z-]+\.ts$/.test(path) && path !== "lib/api/respond.ts";
    if (/^\s*["']use server["']/m.test(source)) problems.push(`R6 ${path}: "use server"`);
    for (const { from, line } of runtimeImports(source)) {
      const at = `${path}:${line}`;
      if (screen && /^(@\/lib\/data\/(postgres|mock)|@\/lib\/db(\/|$)|pg$|server-only$)/.test(from)) problems.push(`R1 ${at}: imports ${from}`);
      if (screen && from === "@/lib/auth/iap") problems.push(`R2 ${at}: imports ${from}`);
      if (isPure) {
        const rel = from.match(/^\.\/([A-Za-z-]+)\.ts$/)?.[1];
        if (rel === undefined || !PURE.includes(rel)) problems.push(`R3 ${at}: runtime import ${from}`);
      }
      if (isApi && !/^(\.\/respond|@\/lib\/api\/respond|server-only|@\/lib\/reports|@\/lib\/sources|@\/lib\/email|@\/lib\/first-orders|@\/lib\/attempts|@\/lib\/funnel)$/.test(from)) problems.push(`R4 ${at}: imports ${from}`);
      if (path === "lib/data/mock.ts" && /^@\/lib\/db(\/|$)/.test(from)) problems.push(`R5 ${at}: imports ${from}`);
    }
  }
  const proxy = files["proxy.ts"] ?? "";
  for (const name of ["x-goog-iap-jwt-assertion", "x-goog-authenticated-user-email", "x-goog-authenticated-user-id"]) {
    if (!proxy.includes(`"${name}"`)) problems.push(`R7 proxy.ts: ${name} is not among the headers deleted before pass()`);
  }
  if (!/for \(const name of IAP_HEADERS\) headers\.delete\(name\);/.test(proxy)) problems.push("R7 proxy.ts: pass() does not delete IAP_HEADERS");
  return problems;
}

const files = Object.fromEntries(walk(root).map((p) => [relative(root, p), readFileSync(p, "utf8")]));
if (process.argv.includes("--provoke")) {
  files["app/x/page.tsx"] = 'import { postgresData } from "@/lib/data/postgres";\nimport { verifyIapJwt } from "@/lib/auth/iap";\n';
  files["lib/csv.ts"] = 'import { NextResponse } from "next/server";\n' + files["lib/csv.ts"];
  files["lib/api/x.ts"] = 'import { data } from "@/lib/data";\n';
  files["app/actions.ts"] = '"use server";\n';
  files["proxy.ts"] = files["proxy.ts"].replace('"x-goog-iap-jwt-assertion", ', "");
}
const problems = check(files);
for (const p of problems) console.log("  " + p);
console.log(problems.length === 0 ? `boundaries: PASS (${Object.keys(files).length} files)` : `boundaries: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
