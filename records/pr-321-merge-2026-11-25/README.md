# The merge of #321 (N07f), 25 November 2026

`Pulse4all-com/cma#321` (addition 0009zt) was merged by Martin on 25 November 2026 at 20:29 as e48e2d2, after
`tools/runners/pr-merge.sh` failed at 20:24.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the facts are his.
His runner's log is not in this folder. No key, no secret, no personal data.

## What happened

| Time | What |
|---|---|
| 20:24 | `pr-merge.sh 321` read `mergeable CONFLICTING, DIRTY` (CHANGELOG, after `Pulse4all-com/cma#329` landed on main) and still tried the merge, which did not happen. |
| 20:24 | Its "merged?" read looped on "failed to parse jq expression" until its 180 s timeout: the `--jq` string lacked jq's own quotes around the interpolation. |
| by 20:29 | Martin merged main into the branch by hand, both CHANGELOG sides kept (8be438b). |
| 20:29 | Martin merged with gh: e48e2d2. The merge touched no `web/` and no `cloudbuild.yaml`, so no prod build. |

## The two runner faults

Both were fixed in the pull request that adds this record:
- `pr-merge.sh` now stops before the merge when GitHub says `CONFLICTING` or `DIRTY`, and asks again while it says `UNKNOWN`.
- The "merged?" read now uses a valid `--jq` expression.

No other runner uses `--jq`.
