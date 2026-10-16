/**
 * Verifier: docs/ingest/deploy.sh against a fake `gcloud` and `curl` on PATH that log every call and
 * answer as dev and prod do (the service account, the database user, the secrets and the image exist,
 * so nothing is created and nothing is built). The script runs in a throwaway copy of the tree (one
 * local commit holding deploy.sh and ingest/, so the image tag is that commit's), the way the A5 run
 * did by hand (docs/a5-audits/local-records/scripts/deploy-fake-gcloud.txt). Needs bash, git and
 * python3; no network, no database, no real gcloud. Everything is invented.
 *
 * The guard of 16 October 2026 (README, Decision log; records/ingest-front-incident-2026-10-16): a
 * prod service deploy without --front stops with exit 2 before any gcloud call, so the ingress and
 * INGEST_PUBLIC_URLS can no longer fall back to all and the run.app addresses only.
 *
 *   node verify/deploy-script.mjs             every check must PASS
 *   node verify/deploy-script.mjs --provoke   every check must FAIL
 */
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, chmodSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/deploy-script.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, "../../docs/ingest/deploy.sh");
const FRONT = "ingest.pulse4all.app";
const RUNAPP = ["https://cma-ingest-100000000001.europe-west4.run.app", "https://cma-ingest-fixture01-ez.a.run.app"];
const REFUSAL = "prod service deploy needs --front <host> (ingest.pulse4all.app); without it ingress goes to all and HubSpot signatures fail";

// ---- The throwaway tree: deploy.sh and an ingest/ in one local commit --------------------------------
const dir = mkdtempSync(path.join(tmpdir(), "deploy-script-"));
const tree = path.join(dir, "tree");
mkdirSync(path.join(tree, "docs/ingest"), { recursive: true });
mkdirSync(path.join(tree, "ingest"));
copyFileSync(SCRIPT, path.join(tree, "docs/ingest/deploy.sh"));
writeFileSync(path.join(tree, "ingest/README"), "a placeholder: the image tag is the last commit under ingest/\n");
// No GIT_* of the caller's environment reaches the tree's git or the script's
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_")));
const git = (...args) => execFileSync("git", ["-c", "user.name=verify", "-c", "user.email=verify@example.com", "-c", "commit.gpgsign=false",
  "-c", "core.hooksPath=/dev/null", ...args], { cwd: tree, env, encoding: "utf8" }).trim();
git("init", "-q");
git("add", "-A");
git("commit", "-q", "-m", "the tree of verify/deploy-script.mjs");
const SHA = git("log", "-1", "--format=%h", "--", "ingest/");

// ---- The fake gcloud and curl ------------------------------------------------------------------------
const bin = path.join(dir, "bin");
mkdirSync(bin);
const LOG = path.join(dir, "gcloud.log");
writeFileSync(path.join(bin, "service.json"), JSON.stringify({
  metadata: { annotations: { "run.googleapis.com/urls": JSON.stringify(RUNAPP) } },
  status: { url: RUNAPP[0] },
}));
writeFileSync(path.join(bin, "gcloud"), `#!/bin/bash
# fake gcloud: every call logged, one line each; answers as a project where everything exists
printf 'gcloud %s\\n' "$*" >> "${LOG}"
proj=""; fmt=""
for a in "$@"; do case "$a" in --project=*) proj="\${a#--project=}";; --format=*) fmt="\${a#--format=}";; esac; done
case "$1 $2 $3" in
  "sql users list") echo "cma-ingest@\${proj}.iam" ;;
  "projects describe "*) echo 100000000002 ;;
  "artifacts repositories get-iam-policy") echo roles/artifactregistry.reader ;;
  "artifacts docker images") echo "sha256:${"0".repeat(64)}" ;;
  "run services describe") if [ "$fmt" = json ]; then cat "${bin}/service.json"; else echo "${RUNAPP[0]}"; fi ;;
  "scheduler jobs describe") exit 1 ;;
esac
exit 0
`);
writeFileSync(path.join(bin, "curl"), `#!/bin/bash
# fake curl: the front's /health answers, the run.app address is refused (404)
for a in "$@"; do [ "$a" = -w ] && { printf 404; exit 0; }; done
printf '{"status":"ok"}'
`);
chmodSync(path.join(bin, "gcloud"), 0o755);
chmodSync(path.join(bin, "curl"), 0o755);

function run(argv) {
  rmSync(LOG, { force: true });
  return new Promise((resolve) => {
    const p = spawn("bash", ["docs/ingest/deploy.sh", ...argv], { cwd: tree, env: { ...env, PATH: `${bin}:${env.PATH}` } });
    let out = "";
    let err = "";
    p.stdout.on("data", (c) => { out += c; });
    p.stderr.on("data", (c) => { err += c; });
    p.on("close", (code) => {
      const calls = existsSync(LOG) ? readFileSync(LOG, "utf8").split("\n").filter(Boolean) : [];
      resolve({ code, out, err, calls });
    });
  });
}
// The service's deploy call: its ingress and its environment variables (gcloud's ^|^ list form)
function serviceDeploy(r) {
  const call = r.calls.find((c) => c.startsWith("gcloud run deploy cma-ingest "));
  if (!call) return { ingress: null, vars: {} };
  const list = (call.match(/ --set-env-vars=\^\|\^(\S+)/) ?? [])[1] ?? "";
  const vars = Object.fromEntries(list.split("|").filter(Boolean).map((kv) => [kv.slice(0, kv.indexOf("=")), kv.slice(kv.indexOf("=") + 1)]));
  return { ingress: (call.match(/ --ingress=(\S+)/) ?? [])[1] ?? null, vars };
}

// ---- A. The guard: prod's service deploy refuses to run without --front -------------------------------
let r = await run(["prod"]);
expect("prod without --front or --jobs → exit 2 with the refusal", [r.code, r.out.trim()], [2, REFUSAL], [0, ""]);
expect("…before any gcloud call", r.calls.length, 0, 12);
r = await run(["prod", "--tenant", "pulse4all-subscriptions", "--secret", "ingest-hubspot-subs-signing", "--secret", "ingest-hubspot-subs-token"]);
expect("prod with --tenant and --secret but no --front → refused, no call", [r.code, r.out.trim(), r.calls.length], [2, REFUSAL, 0], [0, "", 12]);
r = await run(["prod", "--jobs", "--front", FRONT]);
expect("prod --jobs --front → refused as before (--front is the service's)", [r.code, r.out.trim(), r.calls.length], [2, "--front goes with the service deploy, not --jobs", 0], [0, "", 23]);

// ---- B. What still runs: prod's jobs, dev's service, prod's service with --front ----------------------
r = await run(["prod", "--jobs"]);
expect("prod --jobs → exit 0: the six jobs, no service deploy", [r.code, r.calls.filter((c) => c.startsWith("gcloud run jobs deploy ")).length, r.calls.filter((c) => c.startsWith("gcloud run deploy ")).length],
  [0, 6, 0], [2, 0, 1]);
r = await run(["dev"]);
let d = serviceDeploy(r);
expect("dev → exit 0: ingress all, the run.app addresses, replay on", [r.code, d.ingress, d.vars.INGEST_PUBLIC_URLS, d.vars.INGEST_ALLOW_REPLAY], [0, "all", RUNAPP.join(","), "1"],
  [2, "internal-and-cloud-load-balancing", `https://${FRONT},${RUNAPP.join(",")}`, undefined]);
r = await run(["prod", "--front", FRONT, "--tenant", "pulse4all-subscriptions"]);
d = serviceDeploy(r);
expect("prod --front → exit 0 on the image of the last commit under ingest/", [r.code, d.vars.INGEST_VERSION, d.vars.INGEST_PROJECT], [0, SHA, "p4a-cma-prod"], [2, undefined, undefined]);
expect("…--ingress=internal-and-cloud-load-balancing", d.ingress, "internal-and-cloud-load-balancing", "all");
expect("…INGEST_PUBLIC_URLS starts with https://ingest.pulse4all.app", [(d.vars.INGEST_PUBLIC_URLS ?? "").startsWith(`https://${FRONT},`), d.vars.INGEST_PUBLIC_URLS], [true, `https://${FRONT},${RUNAPP.join(",")}`],
  [false, RUNAPP.join(",")]);
expect("…no replay variable in prod, the run.app address refused", ["INGEST_ALLOW_REPLAY" in d.vars, r.out.includes("run.app: 404 (refused)")], [false, true], [true, false]);

rmSync(dir, { recursive: true, force: true });
verdict();
