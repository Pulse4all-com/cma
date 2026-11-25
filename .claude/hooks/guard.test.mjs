import test from "node:test";
import assert from "node:assert/strict";
import { inspectBash, pushesToMain } from "./guard.mjs";

test("pushes to main are found, pushes of a branch are not", () => {
  assert.equal(pushesToMain("git push origin main", "feat"), true);
  assert.equal(pushesToMain("git push -u origin HEAD:main", "feat"), true);
  assert.equal(pushesToMain("git push origin HEAD:refs/heads/main", "feat"), true);
  assert.equal(pushesToMain("git push origin +main", "feat"), true);
  assert.equal(pushesToMain("git push", "main"), true);
  assert.equal(pushesToMain("git push origin HEAD", "main"), true);
  assert.equal(pushesToMain("git push -u origin ccr-e47c13b1-hy49md", "ccr-e47c13b1-hy49md"), false);
  assert.equal(pushesToMain("git push", "feat"), false);
  assert.equal(pushesToMain("git push origin feat/main-menu", "feat"), false);
});

test("segments of a compound command are inspected one by one", () => {
  assert.deepEqual(inspectBash("git add -A && git commit -m x && git push origin main", "feat"), { pushMain: true, ghMerge: false, commitOrPush: true, prodRunner: false });
  assert.deepEqual(inspectBash("gh pr merge 12 --squash", "feat"), { pushMain: false, ghMerge: true, commitOrPush: false, prodRunner: false });
  assert.deepEqual(inspectBash("git log --oneline | head", "feat"), { pushMain: false, ghMerge: false, commitOrPush: false, prodRunner: false });
  assert.deepEqual(inspectBash("echo 'git push origin main'", "feat"), { pushMain: false, ghMerge: false, commitOrPush: false, prodRunner: false });
});

test("the merge runner and the runners that act on prod, however they are started (25 November 2026)", () => {
  assert.equal(inspectBash("cd ~/cma && bash tools/runners/pr-merge.sh 321 " + "a".repeat(40), "feat").ghMerge, true);
  assert.equal(inspectBash("./tools/runners/pr-merge.sh 321 x", "feat").ghMerge, true);
  assert.equal(inspectBash("HEARTBEAT_S=5 bash tools/runners/pr-merge.sh 1 x", "feat").ghMerge, true);
  for (const r of ["n07f-prod", "n07f-ingest", "n07f-first-purge"]) {
    assert.equal(inspectBash(`cd ~/cma && bash tools/runners/${r}.sh`, "feat").prodRunner, true, r);
    assert.equal(inspectBash(`sh /home/user/cma/tools/runners/${r}.sh --now`, "feat").prodRunner, true, r);
  }
  assert.equal(inspectBash("bash tools/runners/n07f-dev.sh", "feat").prodRunner, false);
  assert.equal(inspectBash("bash -n tools/runners/n07f-prod.sh", "feat").prodRunner, false);
  assert.equal(inspectBash("bash -x tools/runners/n07f-prod.sh", "feat").prodRunner, true);
  assert.equal(inspectBash("env PSQL_TIMEOUT=9 bash tools/runners/n07f-first-purge.sh --now", "feat").prodRunner, true);
  assert.equal(inspectBash("grep -n merge tools/runners/pr-merge.sh", "feat").ghMerge, false);
});
