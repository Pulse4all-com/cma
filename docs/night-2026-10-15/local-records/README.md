# Local records, night of 14 to 15 October 2026

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 18.4 from the npm binaries, Node 22.22, and the standalone build of `web/`. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP.

## `db/`

| File | What |
|---|---|
| `order-of-the-fresh-database.txt` | The scripts `00` to `65` in README order, as run on a fresh database; `66` and `67` ran on it afterwards (the files below). |
| `66_invitations-first-run.txt`, `66_invitations-rerun.txt` | The migration, first run (`INSERT 0 1`, `COMMIT`) and rerun (`INSERT 0 0`, nothing new). |
| `67_verify_invitations.txt` | The verify: 23 PASS, verdict PASS. |
| `67_verify_invitations-provoked.txt` | The verify with `verify.provoke`: every check FAIL, verdict `PROVOKED, NOT A PASS` (0 PASS, 23 FAIL). |
| `67_verify_invitations-refused-not-dev.txt` | The verify on a database without the dev seed: `REFUSED`, every block stopped. |
| `63_verify_calls_overview-at67.txt`, `65_verify_calls_history_start-at67.txt` | Both rerun after `66`: 20 and 12 PASS rows. |
| `mutations.py`, `mutations.txt` | Nineteen mutations of `66`, each applied to a copy of the database before `67` ran. Every one was caught; the rows that failed are named. "B39 (the block stopped …)" is `67`'s row for a block that did not run to the end. |
| `earlier-verifies/` | `04` to `65` on the database after `66`, compared with the same scripts on the database at `65`. 26 are identical. `04`, `07`, `10` and `14` differ only in their listings (the table `invitation`, the migration row `0008l`, the two settings); the four diffs are kept. |

## `web/`

| File | What |
|---|---|
| `npm-ci.txt`, `typecheck.txt`, `lint.txt`, `build.txt` | `npm ci`, `npm run typecheck`, `npm run lint` and `npm run build` in `web/`, all exit 0. `build.txt` is the build the browser and API runs below used. |
| `verify-<name>.txt`, `verify-<name>-provoked.txt` | The pure verifiers CLAUDE.md names, plus `signed-out` and `invitations` (new), normal and `--provoke`. |
| `verify-theme*.txt`, `verify-layout*.txt`, `verify-hints*.txt` | The browser verifiers against the build in mock mode, on a freshly started server, normal and provoked. |
| `verify-api-<group>-local-db*.txt` | `verify/api.mjs --invitations`, `--sources`, `--reports`, `--inbound` and `--calls` against the build in mock auth and api data, on the local database at `67` with `verify/reports-fixture.sql`, normal and provoked. |
| `verify-api-invitations-mock*.txt` | `verify/api.mjs --invitations` against the build in mock data, normal and provoked. |
| `screenshots/` | From `verify/layout.mjs` at 1280 px: People with Invitations and the Invite dialog for the admin and the manager, and `/invite` in its five states. Also Configuration → Exports with the Invitations section (admin). |

The full `verify/api.mjs` was not run. At 23:00 in Amsterdam it stops on the seed's workday window (07:00 to 22:00). Its full run is unchanged apart from the health-check line.

## `signed-out/`

| File | What |
|---|---|
| `fake-gcloud/` | Two stand-ins for `gcloud`, each answering reads with canned data. `gcloud-read-only` refuses every change and counts the calls that would change something; `gcloud-permissive` accepts them. Also the three URL maps the dry runs used: `map1.json` has no host rule for the Workspace, `map2.json` a host rule with pathRules, `map3.json` priority 1 taken. |
| `deploy-dev-dry-run.txt` | Dev: bucket only, 0 changing calls. |
| `deploy-prod-dry-run-no-host-rule.txt`, `deploy-prod-dry-run-path-rules.txt` | Prod dry runs on `map1` and `map2`: the plan, the generated validate tests, 0 changing calls. |
| `deploy-prod-dry-run-priority-taken.txt` | Prod on `map3`: stops at the plan and changes nothing. |
| `deploy-prod-dry-run-public-access-prevention.txt` | The organisation policy enforced: stops before anything. |
| `deploy-prod-apply-permissive-fake.txt` | `--apply` against the permissive fake: every step in order, and the restore command. |
| `deploy-prod-apply-foreign-object.txt` | `--apply` with a foreign object in the bucket: stops after the upload check, naming the object. |
| `urlmap-new-path-rules.json`, `urlmap-validate-path-rules.json` | The map `urlmap.py` computed from `map2`, and its validate tests. |
| `rendered-page-example.html` | The page as `deploy.sh` renders it, with an invented display name (HTML-escaped) and the developer's note removed. |
| `screenshots/` | The page in Chromium at 1280 and 390 px, in English and Dutch. |

The fakes print and refuse; nothing here called the real `gcloud`.
