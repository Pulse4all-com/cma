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
  assert.deepEqual(inspectBash("git add -A && git commit -m x && git push origin main", "feat"), { pushMain: true, ghMerge: false, commitOrPush: true });
  assert.deepEqual(inspectBash("gh pr merge 12 --squash", "feat"), { pushMain: false, ghMerge: true, commitOrPush: false });
  assert.deepEqual(inspectBash("git log --oneline | head", "feat"), { pushMain: false, ghMerge: false, commitOrPush: false });
  assert.deepEqual(inspectBash("echo 'git push origin main'", "feat"), { pushMain: false, ghMerge: false, commitOrPush: false });
});
