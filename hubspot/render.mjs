#!/usr/bin/env node
/**
 * Renders one HubSpot developer-platform project per environment from the single template in
 * hubspot/template and the environment's values in hubspot/env/<env>.json.
 *
 *   node hubspot/render.mjs dev --target-url https://<cma-ingest host>/hubspot/<connection key>
 *   node hubspot/render.mjs prod --target-url https://<cma-ingest host>/hubspot/<connection key>
 *   node hubspot/render.mjs dev --draft        placeholder target URL allowed; written to build/dev-draft
 *
 * Output: hubspot/build/<env>/ (git-ignored), ready for `hs project upload` from that directory.
 * A draft goes to hubspot/build/<env>-draft/ so it is never the directory that gets uploaded.
 * The env file holds no portal ids, tokens or secrets; the target URL holds the connection's
 * opaque key, which is not a secret (the request signature is the proof, README Decision log
 * 9 October 2026), and reaches the files through --target-url without editing the env file.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const HUBSPOT_DIR = dirname(fileURLToPath(import.meta.url));
export const TEMPLATE_FILES = ["hsproject.json", "src/app/app-hsmeta.json", "src/app/webhooks/webhook-hsmeta.json"];
const ENV_KEYS = ["appName", "maxConcurrentRequests", "targetUrl", "uidSuffix"];

/** Why a target URL cannot go to HubSpot, or null when it can: https, the ingest's HubSpot route, a real host */
export function targetUrlProblem(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return "not a URL";
  }
  if (/placeholder/i.test(value) || url.hostname.endsWith(".invalid")) return "still the placeholder";
  if (url.protocol !== "https:") return "not https";
  if (url.username || url.password || url.search || url.hash || url.port) return "carries credentials, a port, a query or a fragment";
  if (!/^\/hubspot\/[A-Za-z0-9_-]{24,64}$/.test(url.pathname)) return "path is not /hubspot/<connection key>";
  return null;
}

/** The env file's values, checked: exactly the four keys, nothing else (no portal ids, tokens or secrets) */
export function readEnv(envName) {
  if (!/^[a-z0-9]+$/.test(envName ?? "")) throw new Error(`environment must be a name like dev or prod, got ${envName}`);
  const env = JSON.parse(readFileSync(join(HUBSPOT_DIR, "env", `${envName}.json`), "utf8"));
  const keys = Object.keys(env).sort();
  if (JSON.stringify(keys) !== JSON.stringify(ENV_KEYS)) throw new Error(`env/${envName}.json must hold exactly ${ENV_KEYS.join(", ")}`);
  if (!/^[a-z0-9]{1,20}$/.test(env.uidSuffix)) throw new Error("uidSuffix must be 1 to 20 lower-case letters or digits");
  if (typeof env.appName !== "string" || env.appName.trim().length < 1 || env.appName.length > 80) throw new Error("appName must be 1 to 80 characters");
  if (!Number.isInteger(env.maxConcurrentRequests) || env.maxConcurrentRequests < 1 || env.maxConcurrentRequests > 100) {
    throw new Error("maxConcurrentRequests must be a whole number from 1 to 100");
  }
  if (typeof env.targetUrl !== "string") throw new Error("targetUrl must be a string");
  return env;
}

/** Replaces "{{key}}" in every string; a string that is only a placeholder takes the value's own type */
function fill(node, values) {
  if (Array.isArray(node)) return node.map((x) => fill(x, values));
  if (node && typeof node === "object") return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, fill(v, values)]));
  if (typeof node !== "string") return node;
  const whole = node.match(/^\{\{(\w+)\}\}$/);
  if (whole) {
    if (!(whole[1] in values)) throw new Error(`no value for {{${whole[1]}}}`);
    return values[whole[1]];
  }
  return node.replace(/\{\{(\w+)\}\}/g, (_, k) => {
    if (!(k in values)) throw new Error(`no value for {{${k}}}`);
    return String(values[k]);
  });
}

/**
 * Renders in memory: { files: {path: json text}, targetUrl, draft }. Throws when the target URL is
 * the placeholder or otherwise unfit, unless draft is true.
 */
export function render(envName, { draft = false, targetUrl } = {}) {
  const env = readEnv(envName);
  const url = targetUrl ?? env.targetUrl;
  const problem = targetUrlProblem(url);
  if (problem && !draft) {
    throw new Error(`target URL ${problem}: pass --target-url https://<cma-ingest host>/hubspot/<connection key>, or --draft for a draft`);
  }
  const values = {
    projectName: env.appName,
    appName: env.appName,
    appUid: `cma_ingest_${env.uidSuffix}`,
    webhooksUid: `cma_ingest_webhooks_${env.uidSuffix}`,
    targetUrl: url,
    maxConcurrentRequests: env.maxConcurrentRequests,
  };
  const files = {};
  for (const f of TEMPLATE_FILES) {
    const out = fill(JSON.parse(readFileSync(join(HUBSPOT_DIR, "template", f), "utf8")), values);
    const text = JSON.stringify(out, null, 2) + "\n";
    if (text.includes("{{")) throw new Error(`${f} still holds a placeholder`);
    files[f] = text;
  }
  return { files, targetUrl: url, draft: Boolean(problem) };
}

/** Writes a render to its directory (replacing what was there); answers the directory */
export function write(envName, rendered, outDir) {
  const buildDir = join(HUBSPOT_DIR, "build");
  const dir = resolve(outDir ?? join(buildDir, rendered.draft ? `${envName}-draft` : envName));
  if (!outDir && relative(buildDir, dir).startsWith("..")) throw new Error("refusing to write outside hubspot/build");
  rmSync(dir, { recursive: true, force: true });
  for (const [f, text] of Object.entries(rendered.files)) {
    mkdirSync(dirname(join(dir, f)), { recursive: true });
    writeFileSync(join(dir, f), text);
  }
  return dir;
}

function main(argv) {
  const args = argv.slice(2);
  const envName = args.find((a) => !a.startsWith("--") && args[args.indexOf(a) - 1] !== "--target-url" && args[args.indexOf(a) - 1] !== "--out");
  const draft = args.includes("--draft");
  const at = (flag) => (args.includes(flag) ? args[args.indexOf(flag) + 1] : undefined);
  try {
    const rendered = render(envName, { draft, targetUrl: at("--target-url") });
    const dir = write(envName, rendered, at("--out"));
    const shown = relative(process.cwd(), dir) || ".";
    if (rendered.draft) {
      console.log(`DRAFT ${envName}: ${shown} (target URL is a placeholder; never upload a draft)`);
    } else {
      console.log(`rendered ${envName}: ${shown}\nnext: cd ${shown} && hs project upload`);
    }
    return 0;
  } catch (e) {
    console.error(`refused: ${e.message}`);
    return 2;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv));
}
