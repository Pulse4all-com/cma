# Flash watch and the AI review (design)

Part of the CMA documentation (README.md, Documentation map). Designed with brief B21 (1 November 2026, addition 0008zn); the deterministic watch is built in 0008zn, the AI review is **designed here and built later (B22)**. Nothing in the second half of this document exists yet.

Flash (Reports → Flash, docs/product/features.md) gives ten overviews and Data quality, live and as of any date with a snapshot. After every daily snapshot something has to look at the movements and say what matters. Three reviewers do that, under one rule: **a reviewer advises, a person decides** (Decision log, 1 November 2026: AI review is advisory only).

## 1. Three reviewers, one rule

| Reviewer | What it reads | What it writes | Runs |
|---|---|---|---|
| (a) The deterministic watch (built, 0008zn) | the day's snapshot and the days before it; `sync_run` | `cma.flash_watch_finding` | inside each snapshot take, no AI |
| (b) The Flash review by Claude (B22, designed here) | `cma_read` aggregates only (below) | a digest in `cma.ai_review` | once a day after the snapshots, Cloud Run job `cma-ai-review` |
| (c) Existing reviewers, unchanged | the Gemini Gem "CMA Google Cloud Auditor": the Google Cloud and Workspace setup; Claude Code's `cma-reviewer`: every code change | the Gemini findings doc; PR reviews | as today |

The watch is the first line and the only one that runs without AI. The Flash review reads what the watch found and explains it; it never replaces it.

### (a) The deterministic watch (0008zn)

`cma.flash_watch_of(tenant, date, now)` runs at the end of every take (`cma.flash_snapshot_take`), on the figures just stored, in a subtransaction of its own: a watch that fails leaves its error code on the run (`watch_error`) and the snapshot stored, and the next take runs it again. Its findings hold aggregates, codes and counts only, no id of a record:

| Kind | Raised when | Resolved when |
|---|---|---|
| `jump` | a count of a stock overview per market (its [market] row) moved from the day before by more than `flash.watch_jump_min` and more than `flash.watch_jump_pct` percent of the day before (both days with a snapshot; a market without a row is 0) | the first snapshot where that move no longer holds day over day (the new level held, or no day before to compare) |
| `flow_zero` | a count of a flow overview per market that was above 0 on each of the 7 dates before is 0 or absent | the flow returns, or the 7 dates before are no longer all present |
| `source_stale` | a set-up source's connection last succeeded more than three cadences ago; the cadence is its poll interval setting (a `*_poll_interval_minutes` setting of the connection), else the median gap between its succeeded runs of the last 7 days (no literal; no finding without either). One finding per source, adapter and store: two stale connections alike are one finding with the oldest read and their count (`detail.connections`) | a fresh run brings every such connection's age under three cadences |
| `snapshot_missing` | the date before the one taken has no succeeded snapshot while an earlier one has (a date missed has a run of status `missed`, is never taken afterwards, and the run row's `missed_before` counts them) | the next take, whose date before is present |
| `dq_rise` | a data-quality check (its [check] row) rose from the day before by more than the jump thresholds | the first snapshot where it no longer rose day over day |

One open finding per kind, overview, dims and measure (a condition that holds twice is one finding, so a take never fails on it); a finding moves once from open to resolved, by the take only (the application holds no write on the findings; a guard refuses any other change). Flash shows the open ones in its watch strip; `cma_read.flash_watch_finding` gives them to the readers and to the review below. Thresholds are tenant settings (seed `02`: 20 % and 10 for Pulse4all Subscriptions).

### (b) The Flash review (B22)

A Cloud Run job `cma-ai-review` (europe-west4), started by Cloud Scheduler once a day after the tenants' snapshots (hourly snapshot runs take each tenant's date after its `flash.snapshot_local_time`; the review runs after the last tenant's, e.g. 03:20 UTC), calls Claude on Vertex AI from an EU endpoint and writes one digest per tenant and date.

**What it reads**, through a reader login of its own (`cma_ai_review`, a member of a narrowed reader role) that holds `select` on these `cma_read` views only and no id list, record table or reader view with a record id:

- `cma_read.flash_snapshot`: the day's rows and the previous 28 days' (totals, per market, the breakdowns: codes and figures only);
- `cma_read.flash_snapshot_run`: the runs, their counts, the dates missed;
- `cma_read.flash_watch_finding`: the open findings and those resolved in the last 28 days;
- the data-quality counts and their trend: the `data_quality` overview's rows in `cma_read.flash_snapshot` (per check and market, never a finding's ids);
- System health's runs as aggregates: a view over `cma_read.sync_run` per job and day (counts, statuses, error codes; no stream or connection ids beyond the connection's kind) to be added in B22;
- the last week's lines of CHANGELOG.md (from the repository at the image's commit, not from the database).

It never reads `cma_read.flash_snapshot_ids`, a `dq_` view (those hold record ids), `cma.*`, or any source system.

**What it writes**: the digest, in four sections:

1. *What moved and why it may have*: the figures that moved, against the watch's findings and the week's changes (a deploy, a definition change, a source's outage);
2. *Which findings matter most*: the watch's open findings ranked, with the reason;
3. *Which data fixes would close the largest gaps*: from the data-quality counts and their trend, the checks whose clean-up moves the most figures, with the system where each is fixed;
4. *Which definitions or settings look wrong*: a threshold that fires daily, a definition whose figure contradicts another (for example active customers above active subscriptions).

Each suggestion is classed as one of: a data fix in a source, a setting, a definition, or code.

## 2. Output and the loop

The digest goes into `cma.ai_review` (B22): one row per tenant and date with the model, an input hash (SHA-256 of the exact prompt input, so a digest can be traced to what it read), the sections, and the suggestions each with its class. Insert only, as the snapshots. Flash shows the latest digest beside the watch strip; Welcome shows it to analytics (`performance.team`).

**Nothing is applied automatically.** A person turns a suggestion into one of: a backlog row, a Studio step for Martin, or a Claude Code brief. A code change runs through `cma-reviewer` and Martin's merge like every change. The review writes to the CMA only: never to a source system, a setting or the repository.

"Self-improvement" is exactly this loop, and it is measured, not assumed: by the data-quality burn-down (the `data_quality` overview's trend per check over the snapshots) and by the watch's open findings over time (`cma_read.flash_watch_finding`).

## 3. Data protection

- Aggregates only: no record id, no per-person figure, no free text from a source reaches the prompt. The reader login cannot read one.
- The prompt and the answer are kept in the CMA (`cma.ai_review`, with the input hash) for audit.
- Vertex AI processes in the EU under Google Cloud's terms; no data leaves Google Cloud's EU processing.
- Yordi confirms before the first run (docs/open-decisions.md).

## 4. Prerequisites to verify at build time (B22), not assumed

1. Which current Claude model Vertex AI serves from which EU endpoint: the regional `europe-west4` endpoint versus the `eu` multi-region; the model id is configuration.
2. The Vertex AI API enabled in `p4a-cma-prod` (and dev).
3. A service account `cma-ai-review@<project>` with `roles/aiplatform.user` and the reader login only (no `cma_app`, no `cma_readonly`).
4. The cost per daily run: one request of a few tens of thousands of input tokens per tenant; to measure in dev and write in the PR.
5. A Gemini audit (the Gem) of the IAM and egress before the first prod run.
6. Yordi's yes.

## 5. Later, the same pattern

- A weekly ingest-health review over `sync_run` and the ingest's log metrics (aggregates only).
- A definitions review that compares the metric catalog (`docs/metrics/catalog.json`) with the page copy (`web/src/lib/copy.ts`) and docs/definitions.md, and lists the mismatches as suggestions of class definition.
