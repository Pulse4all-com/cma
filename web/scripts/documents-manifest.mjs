/**
 * Prebuild (npm run build runs it first): the manifest of the documents an admin may download from
 * Configuration → System health (addition 0008r). It lists only files in documents/ whose names are on
 * the allowlist in src/lib/health.ts, with their size and SHA-256, and writes documents/manifest.json.
 * The files themselves come from docs/ in the repository: cloudbuild.yaml copies the allowlisted set
 * into web/documents/ before the Docker build (the build context is web/), so a local build without
 * that step writes an empty manifest and the page says the documents are not in this build.
 *
 * Plain Node, no dependencies; CMA_VERSION (the short SHA Cloud Build passes) names the build.
 */
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const dir = path.join(here, "..", "documents");
mkdirSync(dir, { recursive: true });

// The allowlist, read from the one place it lives (a const array literal in src/lib/health.ts)
const lib = readFileSync(path.join(here, "..", "src", "lib", "health.ts"), "utf8");
const m = lib.match(/export const DOCUMENT_ALLOWLIST: readonly string\[\] = \[([\s\S]*?)\];/);
if (!m) throw new Error("DOCUMENT_ALLOWLIST not found in src/lib/health.ts");
const allow = new Set([...m[1].matchAll(/"([A-Za-z0-9_.-]+)"/g)].map((x) => x[1]));

const documents = [];
for (const name of readdirSync(dir).sort()) {
  if (!allow.has(name)) continue;
  const file = path.join(dir, name);
  if (!statSync(file).isFile()) continue;
  const bytes = readFileSync(file);
  documents.push({ name, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
}
const manifest = { version: process.env.CMA_VERSION ?? "dev", writtenAt: new Date().toISOString(), documents };
writeFileSync(path.join(dir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`documents manifest: ${documents.length} document(s)${documents.length ? ": " + documents.map((d) => d.name).join(", ") : ""}`);
