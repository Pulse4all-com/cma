---
name: pr-description
description: Write the pull request description for a CMA change in the repository's required shape: what changed, why, how it was checked, what Martin still has to run, with labelled command blocks and the reviewers' summaries. Use when a branch is ready and Martin asks for a PR, or before opening one.
---

# PR description

CLAUDE.md (Git and release, Subagents, Instructions for Martin) sets the content. Open a pull request only when Martin asks for one; never merge it. Check for a PR template first (`.github/pull_request_template.md`, `PULL_REQUEST_TEMPLATE.md`, `docs/`); today none exists, so use the sections below and mirror a template's headings if one appears. Everything in English. No secrets, no personal data, no connection strings.

## Gather
- `git log origin/main..HEAD --oneline` and `git diff origin/main...HEAD --stat` (fetch `main` first so the base is current).
- The verifier results you ran, with their real output summary (build, typecheck, lint, each `verify:*`). Never write a result you did not see.
- The reviewers' verdicts (cma-reviewer, cma-db-reviewer, cma-security-reviewer, cma-performance, cma-docs-keeper) and any Critical still open.
- Anything that touches `cloudbuild.yaml`, its substitutions or environment variables.

## Shape
**What changed**: one short paragraph, then the files or areas as a list (web/, db/ with the script numbers and addition version, docs/, tools/).

**Why**: the brief and the decisions made, naming the docs/decisions.md rows and sections.

**How it was checked**: the verifiers that ran in this session with their results, and what could not run here (verifiers that need a server or a database, and every db/ script) with the reason: Martin runs them.

**Review**: `cma-reviewer`'s three-line summary; one line each from the specialised reviewers that ran; the performance opportunities taken and those left (with where they are recorded); any Critical still open after the second round, stated as open; the docs keeper's file list.

**Deploy note**: whether the merge builds and deploys PROD (it does when `web/**` or `cloudbuild.yaml` change; README, `db/`, `docs/`, `records/` do not). Say explicitly when cloudbuild.yaml substitutions or environment variables change, or that they do not.

**What Martin still has to run**: one step at a time, each with the expected output, each block labelled **Studio** (SQL in Cloud SQL Studio, naming `cma-dev-pg` or `cma-prod-pg`), **Terminal** (his own Linux terminal, in ~/cma unless stated), **Browser** (a page or click path) or **File** (a repository path). SQL and shell never in one block. A query that returns customer rows is a Studio block, never Terminal. For a change with a migration, the order is in the `new-migration` skill, section 6.

## Conditional lines
- Table, view or column change in `cma` or `cma_read`: "Martin refreshes docs/datamap/schema.json from dev on this branch after running the migration there, before merging; until then verify:datamap fails on this branch, which is expected."
- `docs/datamap/index.html` changed: end the description with: After merge: in the Claude project, say "republish the data map".
- A new record under records/: say it was written down from Martin's report, and that `node tools/check-records.mjs records/<dir>` passed.

## Close
End with the attribution line the session gives for pull request descriptions. Then ask Martin whether to watch the PR for review comments and CI (`subscribe_pr_activity`).
