# Release record: increment c2 and c2.1, migration 0003a (6 October 2026)

Roadmap step 2, increment c2: the Team hours screen with Correct a day and Add day.
Run by Martin Bartels under his own IAM login (Cloud SQL Studio) and his own Cloud Shell.

## Migration 0003a (`db/11_team_people.sql`)

| Environment | Script | Result |
|---|---|---|
| dev (`cma-dev-pg`) | 11_team_people.sql | Statement executed successfully |
| dev | 12 block A: function and migration row | PASS |
| dev | 12 block B: supervisor lists the people | PASS, 4 people |
| dev | 12 block C: agent refused with CMA06 | PASS |
| dev | 12 block D: no acting user refused with CMA01 | PASS |
| prod (`cma-prod-pg`) | 11_team_people.sql | Statement executed successfully |
| prod | 12 block A: function and migration row | PASS |
| prod | 12 block E: you list the people | PASS, 2 people |

The first run of block A failed with "permission denied for schema cma": a personal login has no
direct rights on schema `cma`. Blocks A and E now switch to `cma_owner` first (commit `440eb78`).

## Web

| Step | Result |
|---|---|
| PR #18 (c2), squash-merged | `f975f82`, prod build SUCCESS 14:23 UTC |
| Local checks before the PR | typecheck (with `next typegen`), lint, copy PASS (124 keys), corrections PASS (21) |
| dev on image `f975f82` (revision `cma-web-00007-jwh`) | API verifier ALL 36 PASS; `--provoke` ALL 36 FAILED, as they must |
| Hand check in prod (Martin) | Team hours on key 3; own rows not correctable; Finn's corrected day with history; Add day without own name; Esc closes |
| PR c2.1 (arrows enter the table, focus returns), squash-merged | `e1f60c9`, prod build SUCCESS 14:51 UTC; copy PASS (125 keys) |
| dev on image `e1f60c9` | API verifier ALL 36 PASS |
| Hand check in prod (Martin) | 3, W, Down, Enter, Esc: focus back on the row |

## Found in prod

- Martin's own day of Monday 5 October is "Not clocked out" (capped at midnight, 6h 07m). Finn
  corrects it; nobody corrects their own day.
