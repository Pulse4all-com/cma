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
 * The guards of 17 October 2026 (audit 5.2-05, DST-01): a checkout that is not on main stops the script
 * before any gcloud call (dev may insist with --allow-branch, with a warning; prod never), as does an
 * uncommitted change under ingest/; and the reconcile's default schedule is 30 3 * * * Europe/Amsterdam,
 * outside the hour the autumn change repeats and the spring change skips.
 *
 * The legacy call import (addition 0008zg, 25 October 2026): the eighth job, ingest-import-legacy-calls, without a
 * schedule and without the scheduler's invoker, running as cma-ingest; the service account reads the import bucket
 * cma-import-<project> through a binding on that bucket only, and a bucket that does not exist yet is named, not made.
 *
 * The asset register poll (addition 0008zj, 27 October 2026): the ninth job, ingest-poll-assets, every 5 minutes
 * (Europe/Amsterdam), its schedule created paused (PROD_RUNBOOK 14.8 resumes it) and an existing one updated without
 * a pause, so a redeploy keeps the state Martin chose.
 *
 * The subscriptions poll (addition 0008zl, 28 October 2026): the tenth job, ingest-poll-subscriptions, every 5 minutes
 * (Europe/Amsterdam), its schedule created paused (PROD_RUNBOOK 15.9 resumes it), an existing one updated without a pause.
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
git("init", "-q", "-b", "main");
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
  "storage buckets describe") [ -e "${bin}/no-bucket" ] && exit 1 ;;
  "sql users list") echo "cma-ingest@\${proj}.iam" ;;
  "projects describe "*) echo 100000000002 ;;
  "artifacts repositories get-iam-policy") echo roles/artifactregistry.reader ;;
  "artifacts docker images") echo "sha256:${"0".repeat(64)}" ;;
  "run services describe") if [ "$fmt" = json ]; then cat "${bin}/service.json"; else echo "${RUNAPP[0]}"; fi ;;
  "scheduler jobs describe") [ -e "${bin}/scheduler-exists" ] || exit 1 ;;
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
expect("prod --jobs → exit 0: the ten jobs, no service deploy", [r.code, r.calls.filter((c) => c.startsWith("gcloud run jobs deploy ")).length, r.calls.filter((c) => c.startsWith("gcloud run deploy ")).length],
  [0, 10, 0], [2, 0, 1]);
// The jobs' pool of 2 (Gemini audit of 28 October 2026, FIND-01): every job its lock and one unit of work; no retries,
// so Cloud Scheduler's start is the only one (FIND-03)
const jobDeploys = r.calls.filter((c) => c.startsWith("gcloud run jobs deploy "));
const poolOf = (c) => ((c.match(/ --set-env-vars=\^\|\^(\S+)/) ?? [])[1] ?? "").split("|").find((kv) => kv.startsWith("CMA_DB_POOL_MAX=")) ?? null;
expect("…each of the ten with CMA_DB_POOL_MAX=2 and --max-retries=0",
  [jobDeploys.map(poolOf).filter((v) => v === "CMA_DB_POOL_MAX=2").length, jobDeploys.filter((c) => c.includes(" --max-retries=0 ")).length], [10, 10], [0, 0]);
const importJob = r.calls.find((c) => c.startsWith("gcloud run jobs deploy ingest-import-legacy-calls ")) ?? "";
expect("…the import job (0008zg): node jobs/import-legacy-calls.mjs as cma-ingest, 6 hours, no arguments",
  [importJob.includes("--command=node,jobs/import-legacy-calls.mjs"), importJob.includes("--service-account=cma-ingest@p4a-cma-prod.iam.gserviceaccount.com"),
    importJob.includes("--task-timeout=6h"), importJob.includes("--args= ")], [true, true, true, true], [false, false, false, false]);
expect("…no schedule and no invoker for it",
  [r.calls.filter((c) => c.startsWith("gcloud scheduler jobs ") && c.includes("ingest-import-legacy-calls")).length,
    r.calls.filter((c) => c.startsWith("gcloud run jobs add-iam-policy-binding ingest-import-legacy-calls ")).length], [0, 0], [1, 1]);
const storageGrants = r.calls.filter((c) => c.includes("storage.objectViewer"));
expect("…storage.objectViewer for cma-ingest on gs://cma-import-p4a-cma-prod only, never on the project",
  [storageGrants.length, (storageGrants[0] ?? "").startsWith("gcloud storage buckets add-iam-policy-binding gs://cma-import-p4a-cma-prod "),
    (storageGrants[0] ?? "").includes("--member=serviceAccount:cma-ingest@p4a-cma-prod.iam.gserviceaccount.com"),
    r.calls.some((c) => c.startsWith("gcloud projects add-iam-policy-binding") && c.includes("storage."))],
  [1, true, true, false], [0, false, false, true]);
writeFileSync(path.join(bin, "no-bucket"), "");
r = await run(["dev", "--jobs"]);
rmSync(path.join(bin, "no-bucket"));
expect("…a bucket that does not exist is named with the runbook, nothing granted or created",
  [r.code, r.out.includes("bucket gs://cma-import-p4a-cma-dev does not exist yet: create it (docs/import/legacy-calls.md, step 1), then rerun with --jobs"),
    r.calls.filter((c) => c.includes("storage.objectViewer") || c.startsWith("gcloud storage buckets create")).length], [0, true, 0], [2, false, 1]);
r = await run(["dev"]);
let d = serviceDeploy(r);
expect("dev → exit 0: ingress all, the run.app addresses, replay on", [r.code, d.ingress, d.vars.INGEST_PUBLIC_URLS, d.vars.INGEST_ALLOW_REPLAY], [0, "all", RUNAPP.join(","), "1"],
  [2, "internal-and-cloud-load-balancing", `https://${FRONT},${RUNAPP.join(",")}`, undefined]);
r = await run(["prod", "--front", FRONT, "--tenant", "pulse4all-subscriptions"]);
d = serviceDeploy(r);
expect("prod --front → exit 0 on the image of the last commit under ingest/", [r.code, d.vars.INGEST_VERSION, d.vars.INGEST_PROJECT], [0, SHA, "p4a-cma-prod"], [2, undefined, undefined]);
expect("…--ingress=internal-and-cloud-load-balancing", d.ingress, "internal-and-cloud-load-balancing", "all");
expect("…the service keeps its pool of 5 (the jobs take 2)", d.vars.CMA_DB_POOL_MAX, "5", "2");
expect("…INGEST_PUBLIC_URLS starts with https://ingest.pulse4all.app", [(d.vars.INGEST_PUBLIC_URLS ?? "").startsWith(`https://${FRONT},`), d.vars.INGEST_PUBLIC_URLS], [true, `https://${FRONT},${RUNAPP.join(",")}`],
  [false, RUNAPP.join(",")]);
expect("…no replay variable in prod, the run.app address refused", ["INGEST_ALLOW_REPLAY" in d.vars, r.out.includes("run.app: 404 (refused)")], [false, true], [true, false]);

// ---- C. Main only: a checkout on another branch, or with uncommitted changes, is refused before any call -----
git("switch", "-q", "-c", "other");
r = await run(["prod", "--front", FRONT]);
expect("prod on a branch → exit 2 (main only), no call", [r.code, r.out.trim(), r.calls.length],
  [2, "prod deploys from main only (this checkout is on other): git switch main && git pull --ff-only, then rerun", 0], [0, "", 12]);
r = await run(["prod", "--jobs"]);
expect("prod --jobs on a branch → refused too", [r.code, r.calls.length], [2, 0], [0, 23]);
r = await run(["dev"]);
expect("dev on a branch → exit 2 naming --allow-branch, no call", [r.code, r.out.includes("deploy from main only (this checkout is on other)"), r.out.includes("dev --allow-branch insists"), r.calls.length],
  [2, true, true, 0], [0, false, false, 12]);
r = await run(["dev", "--allow-branch"]);
expect("dev --allow-branch → runs, with the warning naming the branch and the image tag", [r.code, r.out.includes(`WARNING: deploying dev from branch other, not main (--allow-branch): image tag ${SHA} is a branch commit no review merged`),
  r.calls.filter((c) => c.startsWith("gcloud run deploy ")).length], [0, true, 1], [2, false, 0]);
r = await run(["prod", "--front", FRONT, "--allow-branch"]);
expect("prod --allow-branch → refused (dev only), no call", [r.code, r.out.trim(), r.calls.length], [2, "--allow-branch is for dev; prod deploys from main only", 0], [0, "", 12]);
writeFileSync(path.join(tree, "ingest/README"), "an uncommitted change\n");
r = await run(["dev", "--allow-branch"]);
expect("an uncommitted change under ingest/ → refused even with --allow-branch, no call", [r.code, r.out.trim(), r.calls.length],
  [2, "ingest/ or docs/ingest/deploy.sh has uncommitted changes; deploy from a clean checkout of main", 0], [0, "", 12]);
git("checkout", "--", "ingest/README");
git("switch", "-q", "main");
r = await run(["dev", "--allow-branch"]);
expect("on main --allow-branch changes nothing (no warning)", [r.code, r.out.includes("WARNING"), r.calls.filter((c) => c.startsWith("gcloud run deploy ")).length], [0, false, 1], [2, true, 0]);

// ---- D. The reconcile's default schedule (DST-01): 03:30 Europe/Amsterdam ------------------------------------
const schedule = (job) => (r.calls.find((c) => c.startsWith(`gcloud scheduler jobs create http ${job} `)) ?? "").match(/ --schedule=(.+?) --time-zone=(\S+)/)?.slice(1) ?? [];
r = await run(["prod", "--jobs"]);
expect("prod --jobs schedules the reconcile at 30 3 * * * Europe/Amsterdam by default", [schedule("ingest-reconcile"), r.out.includes("schedule ingest-reconcile: 30 3 * * * (Europe/Amsterdam)")],
  [["30 3 * * *", "Europe/Amsterdam"], true], [["30 2 * * *", "Europe/Amsterdam"], false]);
expect("…the every-minute jobs as before", ["ingest-sweep", "ingest-poll-forms", "ingest-poll-email"].map((j) => schedule(j)[0]), ["* * * * *", "* * * * *", "* * * * *"], []);
expect("…the reviews poll hourly at minute 7, Europe/Amsterdam (addition 0008ze)", [schedule("ingest-poll-reviews"), r.out.includes("schedule ingest-poll-reviews: 7 * * * * (Europe/Amsterdam)")],
  [["7 * * * *", "Europe/Amsterdam"], true], [["* * * * *", "Europe/Amsterdam"], false]);
const assetsJob = r.calls.find((c) => c.startsWith("gcloud run jobs deploy ingest-poll-assets ")) ?? "";
expect("…the asset register poll (0008zj): node jobs/poll-assets.mjs, 10 minutes, every 5 minutes, created paused",
  [assetsJob.includes("--command=node,jobs/poll-assets.mjs"), assetsJob.includes("--task-timeout=10m"), schedule("ingest-poll-assets"),
    r.calls.filter((c) => c.startsWith("gcloud scheduler jobs pause ingest-poll-assets ")).length,
    r.out.includes("schedule ingest-poll-assets: */5 * * * * (Europe/Amsterdam), created paused")],
  [true, true, ["*/5 * * * *", "Europe/Amsterdam"], 1, true], [false, false, [], 0, false]);
const subsJob = r.calls.find((c) => c.startsWith("gcloud run jobs deploy ingest-poll-subscriptions ")) ?? "";
expect("…the subscriptions poll (0008zl): node jobs/poll-subscriptions.mjs, 10 minutes, every 5 minutes, created paused",
  [subsJob.includes("--command=node,jobs/poll-subscriptions.mjs"), subsJob.includes("--task-timeout=10m"), schedule("ingest-poll-subscriptions"),
    r.calls.filter((c) => c.startsWith("gcloud scheduler jobs pause ingest-poll-subscriptions ")).length,
    r.out.includes("schedule ingest-poll-subscriptions: */5 * * * * (Europe/Amsterdam), created paused")],
  [true, true, ["*/5 * * * *", "Europe/Amsterdam"], 1, true], [false, false, [], 0, false]);
expect("…no other schedule paused, the outbox's aside",
  r.calls.filter((c) => c.startsWith("gcloud scheduler jobs pause ") && !c.includes("ingest-poll-assets") && !c.includes("ingest-poll-subscriptions")).length, 0, 1);
writeFileSync(path.join(bin, "scheduler-exists"), "");
r = await run(["prod", "--jobs"]);
rmSync(path.join(bin, "scheduler-exists"));
expect("…an existing schedule updated, never paused again (a redeploy keeps the state)",
  [r.calls.some((c) => c.startsWith("gcloud scheduler jobs update http ingest-poll-assets ")), r.calls.filter((c) => c.startsWith("gcloud scheduler jobs pause ingest-poll-assets ")).length,
    r.out.includes("schedule ingest-poll-assets: */5 * * * * (Europe/Amsterdam)\n"),
    r.calls.filter((c) => c.startsWith("gcloud scheduler jobs pause ingest-poll-subscriptions ")).length,
    r.out.includes("schedule ingest-poll-subscriptions: */5 * * * * (Europe/Amsterdam)\n")],
  [true, 0, true, 0, true], [false, 1, false, 1, false]);
r = await run(["dev", "--jobs", "--reconcile-every", "*/2 * * * *", "--reconcile-lookback", "10"]);
expect("--reconcile-every and --reconcile-lookback still set the polling fallback", [schedule("ingest-reconcile")[0], (r.calls.find((c) => c.startsWith("gcloud run jobs deploy ingest-reconcile ")) ?? "").includes("--args=--lookback-minutes,10")],
  ["*/2 * * * *", true], ["30 3 * * *", false]);
r = await run(["dev", "--reconcile-every", "*/2 * * * *"]);
expect("…and without --jobs a schedule other than the default is refused", [r.code, r.out.trim()], [2, "--reconcile-every and --reconcile-lookback go with --jobs"], [0, ""]);

rmSync(dir, { recursive: true, force: true });
verdict();
