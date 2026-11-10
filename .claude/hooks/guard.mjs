#!/usr/bin/env node
/**
 * Project hooks that enforce CLAUDE.md rules the harness can check (Git and release; Database). Plain Node, no
 * dependencies. One script for three hooks, told apart by the event on stdin (see .claude/settings.json):
 *
 *   PreToolUse  Bash                        blocks a push to main, `gh pr merge`, and a commit or push that carries
 *                                           records/ files failing tools/check-records.mjs
 *   PreToolUse  mcp__github__merge_pull_request, enable_pr_auto_merge
 *                                           blocks the merge: Martin reviews and squash-merges
 *   PostToolUse Edit|Write                  reminds (never blocks) when cloudbuild.yaml changes, or an existing db/ script
 *                                           is edited
 *
 * Exit 2 with the reason on stderr blocks the call and tells Claude why; exit 0 lets it through. A hook that cannot
 * decide (unreadable input, no git) lets the call through: the rules in CLAUDE.md still apply.
 * Unit test: node --test .claude/hooks/guard.test.mjs
 */
import { execFileSync } from "node:child_process";
import { relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const git = (args, cwd) => {
  try {
    return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
};

/** The refspec words of a `git push` segment, flags removed */
function pushWords(segment) {
  const words = segment.trim().split(/\s+/).slice(2).filter((w) => !w.startsWith("-"));
  return words; // [remote, refspec...]
}

/** True when this `git push` segment would update main or master */
export function pushesToMain(segment, currentBranch) {
  const [, ...refs] = pushWords(segment);
  if (refs.length === 0) return currentBranch === "main" || currentBranch === "master";
  return refs.some((r) => {
    const dst = r.includes(":") ? r.split(":").pop() : r;
    const name = dst.replace(/^\+/, "").replace(/^refs\/heads\//, "");
    return name === "main" || name === "master" || (r === "HEAD" && (currentBranch === "main" || currentBranch === "master"));
  });
}

/** What a Bash command asks for, by segment (split on ; && || | and newlines) */
export function inspectBash(command, currentBranch) {
  const segments = command.split(/&&|\|\||;|\||\n/).map((s) => s.trim()).filter(Boolean);
  const out = { pushMain: false, ghMerge: false, commitOrPush: false };
  for (const s of segments) {
    if (/^git\s+(-C\s+\S+\s+)?push\b/.test(s)) {
      out.commitOrPush = true;
      const normalised = s.replace(/^git\s+-C\s+\S+\s+/, "git ");
      if (pushesToMain(normalised, currentBranch)) out.pushMain = true;
    } else if (/^git\s+(-C\s+\S+\s+)?commit\b/.test(s)) {
      out.commitOrPush = true;
    } else if (/^gh\s+pr\s+merge\b/.test(s)) {
      out.ghMerge = true;
    }
  }
  return out;
}

function block(reason) {
  process.stderr.write(reason + "\n");
  process.exit(2);
}

function remind(text) {
  process.stdout.write(
    JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text } }) + "\n",
  );
  process.exit(0);
}

function recordsChanged(cwd) {
  const names = new Set();
  // Staged files, and the commits not pushed yet: against the branch's upstream, which a fetch keeps current; only
  // without an upstream against origin/main (a local ref that can lag, so it is the fallback, not the rule).
  const base = git(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd) ?? "origin/main";
  const lists = [
    git(["diff", "--name-only", "--cached", "--", "records"], cwd),
    git(["diff", "--name-only", `${base}...HEAD`, "--", "records"], cwd),
  ];
  for (const l of lists) for (const n of (l ?? "").split("\n")) if (n) names.add(n);
  return [...names];
}

function main() {
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch {
    process.exit(0);
  }
  const cwd = input.cwd || process.cwd();
  const root = git(["rev-parse", "--show-toplevel"], cwd);
  const event = input.hook_event_name;
  const tool = input.tool_name || "";

  if (event === "PreToolUse" && /^mcp__github__(merge_pull_request|enable_pr_auto_merge)$/.test(tool)) {
    block("Blocked: never merge a pull request yourself, and never turn on auto-merge. Martin reviews and squash-merges (CLAUDE.md, Git and release).");
  }

  if (event === "PreToolUse" && tool === "Bash") {
    const command = input.tool_input?.command ?? "";
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd);
    const seen = inspectBash(command, branch);
    if (seen.pushMain) block("Blocked: never push to main; it only accepts pull requests. Push your branch (git push -u origin <branch>) (CLAUDE.md, Git and release).");
    if (seen.ghMerge) block("Blocked: never merge a pull request yourself. Martin reviews and squash-merges (CLAUDE.md, Git and release).");
    if (seen.commitOrPush && root) {
      const files = recordsChanged(root);
      if (files.length > 0) {
        try {
          execFileSync("node", [resolve(root, "tools/check-records.mjs"), ...files.map((f) => resolve(root, f))], {
            cwd: root,
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          });
        } catch (e) {
          const text = `${e.stdout ?? ""}${e.stderr ?? ""}`.trim();
          block(
            "Blocked: records/ files in this change fail tools/check-records.mjs (CLAUDE.md: raw prod output is masked or left out before any commit or push).\n" +
              text.split("\n").slice(-12).join("\n"),
          );
        }
      }
    }
  }

  if (event === "PostToolUse" && (tool === "Edit" || tool === "Write")) {
    const file = input.tool_input?.file_path;
    if (file && root) {
      const rel = relative(root, resolve(cwd, file));
      if (rel === "cloudbuild.yaml") {
        remind("cloudbuild.yaml changed: say explicitly in the PR what changed, above all any substitution or environment variable (CLAUDE.md, Git and release). A merge that touches it builds and deploys PROD.");
      }
      // Committed already: it may have run in prod. Never compared with origin/main, which can be a stale local ref
      // (a script merged since the last fetch would then read as new and the hook would stay silent).
      if (/^db\/.+\.sql$/.test(rel) && git(["ls-files", "--error-unmatch", rel], root) !== null) {
        remind(`${rel} is already committed. A script that has run in prod is never edited: a change is a new numbered script plus its verify script (CLAUDE.md, Database). If this script was added on this branch and has not run anywhere, carry on; otherwise revert this edit and write a new script.`);
      }
    }
  }
  process.exit(0);
}

function readStdin() {
  return execFileSync("cat", [], { encoding: "utf8", stdio: ["inherit", "pipe", "ignore"] });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
