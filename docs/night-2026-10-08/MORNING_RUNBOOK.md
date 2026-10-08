# Morning runbook: releasing the night build of 7 to 8 October 2026

Five patches, applied to `main` in order, each its own pull request. The order per slice is the README's: migration in dev → migration in prod → merge → the same image on dev → the API verifier → a hand check in prod. Slices 1 and 3 are database only (no build); 2 and 4 are web (a merge builds and deploys prod); 5 is documents. Read `NIGHT_NOTES.md` section 1 first: `main`'s README is the eleventh pass.

Labels: **Studio** (Cloud SQL Studio, instance named; first statement `set role cma_owner;`), **Terminal** (Cloud Shell, `~/cma` unless stated), **Browser**, **File**. SQL and shell never share a block. Expected outputs are given after each block.

## 0. Start of the morning

**Browser:** Cloud Shell → ⋮ → Upload: `night-01-0004.patch`, `night-02-team.patch`, `night-03-0005.patch`, `night-04-roster.patch`, `night-05-readme.patch` (they land in `~`).

**Terminal**
```bash
command -v nvm >/dev/null || source /usr/local/nvm/nvm.sh
nvm install 22 >/dev/null && nvm use 22 >/dev/null && node -v
cd ~/cma && git switch main -q && git pull -q --ff-only && git log --oneline -1
git apply --check ~/night-01-0004.patch && echo "night-01-0004.patch applies"
```
Expected: `d2d03e7 README: fourteenth pass …`, then `night-01-0004.patch applies`. Patches 2 to 5 build on each other, so only the first can be checked against `main` alone; the night applied all five in sequence on a fresh clone of `d2d03e7` and the tree came out identical to its branch. If `git pull` brings anything newer than `d2d03e7`, stop: the patches were cut against `d2d03e7`, and a newer `main` needs the night's successor to rebase them.

A helper that applies one patch on a fresh branch and commits it with its own message:

**Terminal**
```bash
apply_night () {  # usage: apply_night <branch> <patch file>
  cd ~/cma && git switch -q -c "$1" && git am -q --committer-date-is-author-date "$2" && git log --oneline -1
}
```
`git am` keeps the night's commit message and author (`Night build <night-build@pulse4all.invalid>`); the pull request and squash merge make you the committer, as every PR does.

## 1. Slice 1: migration 0004, teams and skills, the admin role

### 1.1 Apply the patch

**Terminal**
```bash
apply_night night-01-0004 ~/night-01-0004.patch
git show --stat --format= HEAD | tail -8
```
Expected: one commit "0004: teams, skills and level scales …"; files `db/02`, `03`, `06`, `14`, `21`, `22` and `records/0004-dev-2026-10-08/README.md`.

### 1.2 Dev: run the migration, rerun the seeds, verify

**Studio (cma-dev-pg, database cma)** — paste and run, one file at a time, in this order:
1. `db/21_teams_skills.sql` → last result: one row, the migration recorded.
2. `db/02_seed_pulse4all.sql` (rerun: the Pulse4all teams and skills) → the two tenant ids, notices only.
3. `db/03_seed_dev_test_data.sql` (rerun: the admin user and role, the memberships and skills) → no error.
4. `db/06_seed_dev_time_model.sql` (rerun: the admin's mock login id; the time fixture is skipped as already present) → `time model fixture already present, skipped` is expected.
5. `db/22_verify_teams_skills.sql` → last result (the verdict):

| tenant | roles_with_configure | roles_with_manage_all | teams | skills | verdict |
|---|---|---|---|---|---|
| pulse4all-invest | admin | admin | 0 | 0 | PASS |
| pulse4all-subscriptions | admin | admin | 5 | 11 | PASS |

6. `db/14_verify_tenant_settings.sql` (rerun: it now accepts the admin) → last result PASS on both tenants.

The provoked run and the records, from the Terminal through the Auth Proxy (as `records/0003b-dev-2026-10-07` was made):

**Terminal**
```bash
cd ~/cma && mkdir -p records/0004-dev-2026-10-08
cloud-sql-proxy --auto-iam-authn --port 5433 p4a-cma-dev:europe-west4:cma-dev-pg >/tmp/proxy-dev.log 2>&1 &
sleep 4
PGCONN="host=127.0.0.1 port=5433 dbname=cma user=$(gcloud config get-value account) sslmode=disable"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/22_verify_teams_skills.sql 2>&1 | tee records/0004-dev-2026-10-08/verify-0004.txt | tail -4
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/22_verify_teams_skills.sql > /tmp/22p.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/22p.sql 2>&1 | tee records/0004-dev-2026-10-08/verify-0004-provoke.txt | grep -E "FAIL|PROVOKED"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/14_verify_tenant_settings.sql 2>&1 | tee records/0004-dev-2026-10-08/verify-0003b-rerun.txt | tail -3
rm records/0004-dev-2026-10-08/README.md
```
Expected: the verdict rows as above; provoked: `FAIL A2`, `FAIL B2`, then two verdict rows `PROVOKED, NOT A PASS`; `14`: PASS on both tenants.

### 1.3 Prod: point-in-time recovery, the migration, the seed, verify

**Browser:** Console → SQL → cma-prod-pg → Backups: point-in-time recovery enabled (or take an on-demand backup first).

**Studio (cma-prod-pg, database cma)** — in this order:
1. `db/21_teams_skills.sql` → the migration recorded.
2. `db/02_seed_pulse4all.sql` (rerun) → the two tenant ids.
3. `db/22_verify_teams_skills.sql` → verdict PASS on both tenants: invest `0 | 0`, subscriptions `5 | 11`.
4. `db/14_verify_tenant_settings.sql` (rerun) → PASS.

**Terminal** (records; a second proxy on another port)
```bash
cd ~/cma && mkdir -p records/0004-prod-2026-10-08
cloud-sql-proxy --auto-iam-authn --port 5434 p4a-cma-prod:europe-west4:cma-prod-pg >/tmp/proxy-prod.log 2>&1 &
sleep 4
PGPROD="host=127.0.0.1 port=5434 dbname=cma user=$(gcloud config get-value account) sslmode=disable"
psql "$PGPROD" -v ON_ERROR_STOP=1 -f db/22_verify_teams_skills.sql 2>&1 | tee records/0004-prod-2026-10-08/verify-0004.txt | tail -4
psql "$PGPROD" -v ON_ERROR_STOP=0 -f /tmp/22p.sql 2>&1 | tee records/0004-prod-2026-10-08/verify-0004-provoke.txt | grep -E "FAIL|PROVOKED"
```
Expected: as in dev with `0 | 0` and `5 | 11`.

### 1.4 Prod: Martin becomes admin (one statement, as cma_owner)

`cma.set_person_role()` refuses one's own role and nobody else in prod holds `users.manage_all`, so this one change is made as the owner under your personal login; the audit row names your login.

**Studio (cma-prod-pg, database cma)**
```sql
set role cma_owner;
select t.slug, u.email, ar.key as role
from cma.user_role ur
join cma.app_user u  on u.tenant_id = ur.tenant_id and u.id = ur.user_id
join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
join cma.tenant t    on t.id = u.tenant_id
order by t.slug, u.email;
```
Expected: Martin `manager`, Finn `supervisor`, in `pulse4all-subscriptions`. Then, with your own email where it says so:

**Studio (cma-prod-pg, database cma)**
```sql
set role cma_owner;
update cma.user_role ur
set role_id = (select id from cma.app_role where tenant_id = ur.tenant_id and key = 'admin')
from cma.app_user u, cma.tenant t
where ur.tenant_id = u.tenant_id and ur.user_id = u.id and u.tenant_id = t.id
  and t.slug = 'pulse4all-subscriptions'
  and u.email = 'martin@pulse4all.com'
  and ur.role_id = (select id from cma.app_role where tenant_id = ur.tenant_id and key = 'manager');
select u.email, ar.key as role from cma.user_role ur
join cma.app_user u on u.id = ur.user_id join cma.app_role ar on ar.id = ur.role_id
where u.email = 'martin@pulse4all.com';
```
Expected: `UPDATE 1`, then `martin@pulse4all.com | admin`. Joshua later goes through the People screen as `admin` when V1 goes live (Decision log, 7 October).

### 1.5 Merge

**Terminal**
```bash
cd ~/cma && git add records/ && git status --short
git commit -q -m "0004 records: dev and prod verify, normal and provoked, 8 October" && git push -q -u origin HEAD
gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only && git log --oneline -1
```
Expected: a PR merged; no build (nothing under `web/`).

## 2. Slice 2: the People screen

### 2.1 Apply, build, verify locally

**Terminal**
```bash
apply_night night-02-team ~/night-02-team.patch
cd ~/cma/web && npm ci --no-audit --no-fund 2>&1 | tail -1
npm run typecheck 2>&1 | tail -2 && npm run lint 2>&1 | tail -1
npm run build 2>&1 | tail -3; echo "build exit: ${PIPESTATUS[0]}"
npm run verify:copy && npm run verify:team && npm run verify:live
cp -r .next/static .next/standalone/.next/ && cp -r public .next/standalone/
```
Expected: no type or lint errors; `build exit: 0`; `copy: PASS (310 keys, en and nl)`, `team: PASS (18 checks)`, `ALL 26 PASS`.

**Terminal (second tab)**
```bash
cd ~/cma/web && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```

**Terminal (first tab)**
```bash
cd ~/cma/web && npm run verify:theme && npm run verify:layout
```
Expected: `theme: PASS (10 pages, …)`, `layout: PASS (… navigation for 5 identities …)`; the screenshots land in `records/layout/`. Stop the second tab (Ctrl+C) afterwards.

### 2.2 Merge, the image on dev, the API verifier

**Terminal**
```bash
cd ~/cma && git add records/layout && git commit -q -m "layout screenshots, slice 2" ; git push -q -u origin HEAD
gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Wait for SUCCESS (2 to 4 minutes; rerun the last command). Then:

**Terminal**
```bash
sha=<short sha from the build>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
cd ~/cma/web && mkdir -p ../records/team-2026-10-08 && rm -f ../records/team-2026-10-08/README.md
node verify/api.mjs | tee ../records/team-2026-10-08/verify-api.txt | tail -2
node verify/api.mjs --provoke | tee ../records/team-2026-10-08/verify-api-provoke.txt | tail -1
```
Expected: `version` = `$sha`, `auth mock`, `data api`; `ALL 89 PASS`; `ALL 89 PROVOKED CHECKS FAILED, as they must`. The run adds `verify-added@example.com` to dev (inactive at the end) and leaves it there, like the test agent's days.

### 2.3 Hand check in prod

**Browser:** workspace.pulse4all.app as yourself.
- The rail shows a **Team** group between Live and Time; People is page 3, Roster absent until slice 4.
- People: you (Admin, "Manages people", Edit disabled with "This is you"), Finn (Supervisor, Edit enabled), both Active with Clock.
- Edit Finn: the role list offers every role (you are admin); set no change, Esc; Esc closes.
- Add a person: do not add anyone yet (Joshua waits for go-live). Open and cancel the dialog.
- Live board: the Team column and filter (empty until people are in teams).

Then record and commit:

**Terminal**
```bash
cd ~/cma && git switch -q -c records-team && git add records/team-2026-10-08 && git commit -q -m "team records: API verifier 89, dev on $sha" && git push -q -u origin HEAD && gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only
```

## 3. Slice 3: migration 0005, the roster

### 3.1 Apply

**Terminal**
```bash
apply_night night-03-0005 ~/night-03-0005.patch
```
Expected: one commit "0005: the roster …"; files `db/23`, `24`, `25`, the records placeholder.

### 3.2 Dev

**Studio (cma-dev-pg, database cma)** — in this order:
1. `db/23_roster.sql` → the migration recorded.
2. `db/24_seed_dev_roster.sql` → notice `roster fixture written (n cells this week, next week as a draft)`; n depends on the weekday (on a Thursday 5).
3. `db/25_verify_roster.sql` → verdict:

| tenant | roles_with_roster_manage | roles_with_roster_view | absence_types | roster_weeks | verdict |
|---|---|---|---|---|---|
| pulse4all-invest | admin, manager | admin, agent, manager, supervisor | 5 | 0 | PASS |
| pulse4all-subscriptions | admin, manager | admin, agent, manager, supervisor | 5 | 3 | PASS |

**Terminal** (records through the dev proxy from step 1.2)
```bash
cd ~/cma && mkdir -p records/0005-dev-2026-10-08 && rm -f records/0005-dev-2026-10-08/README.md
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/25_verify_roster.sql 2>&1 | tee records/0005-dev-2026-10-08/verify-0005.txt | tail -4
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/25_verify_roster.sql > /tmp/25p.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/25p.sql 2>&1 | tee records/0005-dev-2026-10-08/verify-0005-provoke.txt | grep -E "FAIL|PROVOKED"
for f in 16_verify_team_status_time 18_verify_clock_in_app_links 20_verify_team_now; do psql "$PGCONN" -v ON_ERROR_STOP=1 -At -f db/$f.sql 2>&1 | tail -1; done
```
Expected: the verdict as above; provoked `FAIL A2`, `FAIL B1`, verdicts `PROVOKED, NOT A PASS`; `16`, `18`, `20` end in PASS (they use `create_tenant`, which 0004 and 0005 redefine).

### 3.3 Prod

**Browser:** point-in-time recovery confirmed on cma-prod-pg.

**Studio (cma-prod-pg, database cma)**
1. `db/23_roster.sql` → recorded.
2. `db/25_verify_roster.sql` → PASS on both tenants, `5 | 0` each.

**Terminal**
```bash
cd ~/cma && mkdir -p records/0005-prod-2026-10-08
psql "$PGPROD" -v ON_ERROR_STOP=1 -f db/25_verify_roster.sql 2>&1 | tee records/0005-prod-2026-10-08/verify-0005.txt | tail -4
psql "$PGPROD" -v ON_ERROR_STOP=0 -f /tmp/25p.sql 2>&1 | tee records/0005-prod-2026-10-08/verify-0005-provoke.txt | grep -E "FAIL|PROVOKED"
```

### 3.4 Merge

**Terminal**
```bash
cd ~/cma && git add records/ && git commit -q -m "0005 records: dev and prod verify, normal and provoked, 8 October" && git push -q -u origin HEAD
gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only
```
No build.

## 4. Slice 4: the roster screens

### 4.1 Apply, build, verify locally

**Terminal**
```bash
apply_night night-04-roster ~/night-04-roster.patch
cd ~/cma/web && npm run typecheck 2>&1 | tail -2 && npm run lint 2>&1 | tail -1
npm run build 2>&1 | tail -3; echo "build exit: ${PIPESTATUS[0]}"
npm run verify:copy && npm run verify:roster && npm run verify:live
cp -r .next/static .next/standalone/.next/ && cp -r public .next/standalone/
```
Expected: `copy: PASS (388 keys, en and nl)`, `roster: PASS (31 checks)`, `ALL 26 PASS`, `build exit: 0`. Then the mock server in a second tab as in 2.1 and:

**Terminal**
```bash
cd ~/cma/web && npm run verify:theme && npm run verify:layout
```
Expected: `theme: PASS (13 pages, …)`, `layout: PASS (… the shift line and navigation for 5 identities …)`.

**Browser (Web preview, port 8080, mock):** `/?as=manager` → Roster: the planner shows this week for Team NL with cells; type `9-17` in a future cell, Enter → "Saved"; type `zzz` → the format message; Publish (U) → confirm → "Published as version 2"; Print (X) opens the print view in a new tab; `/?as=agent-one` → My schedule shows this week's shifts and next week as not published.

### 4.2 Merge, the image on dev, the API verifier

**Terminal**
```bash
cd ~/cma && git add records/layout && git commit -q -m "layout screenshots, slice 4" ; git push -q -u origin HEAD
gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
After SUCCESS:

**Terminal**
```bash
sha=<short sha from the build>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
cd ~/cma/web && mkdir -p ../records/roster-2026-10-08 && rm -f ../records/roster-2026-10-08/README.md
node verify/api.mjs | tee ../records/roster-2026-10-08/verify-api.txt | tail -2
node verify/api.mjs --provoke | tee ../records/roster-2026-10-08/verify-api-provoke.txt | tail -1
```
Expected: `ALL 111 PASS`; `ALL 111 PROVOKED CHECKS FAILED, as they must`. The roster checks plan two weeks ahead on Agent Two's team and clear it again.

### 4.3 Hand check in prod

**Browser:** workspace.pulse4all.app as yourself.
- Welcome: the date line carries "Today's roster has not been published yet" (no roster in prod yet).
- Team → Roster: Team EN (the first team) with nobody on it: "Nobody is on this roster: add people to the team on People". Everyone: you and Finn on the grid. Type a shift for Finn on a future day, Enter → Saved; Publish → version 1. Open the print view (X) and use Save as file in Chrome's print dialog: an A4 landscape PDF with the header, the grid and the footer. Clear Finn's cell again (empty, Enter) and Publish again, so prod holds no plan nobody meant.
- Live board: a Shift column ("Not published" or "No shift"), the Team column.
- Time → My schedule: your own week, "Not published yet" or "No shift".

**Terminal**
```bash
cd ~/cma && git switch -q -c records-roster && git add records/roster-2026-10-08 && git commit -q -m "roster records: API verifier 111, dev on $sha" && git push -q -u origin HEAD && gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only
```

## 4b. Slice 4b: the print fix (added on the morning of 8 October)

The first print in prod showed the narrow-screen gate instead of the sheet. Apply, build, verify as in 4.1 (`npm run verify:theme` and `verify:layout` against the mock server), merge; the build deploys prod and the dev image follows as in 4.2 (the API verifier stays at 111). Hand check: Roster → Print (X) → the print dialog shows the sheet.

**Terminal**
```bash
apply_night night-04b-print ~/night-04b-print.patch
```

## 5. Slice 5: README fifteenth pass, the template retired, the night's documents

**Terminal**
```bash
apply_night night-05-readme ~/night-05-readme.patch
cd ~/cma && git show --stat --format= HEAD | tail -6
grep -c "night build" README.md && tail -c 400 README.md | head -c 200; echo
git push -q -u origin HEAD && gh pr create --fill && gh pr merge --squash --delete-branch && git switch -q main && git pull -q --ff-only && git log --oneline -1 -- README.md
```
Expected: `README.md` replaced whole (1096 lines; the diff against `main` is large because `main` holds the eleventh pass, see NIGHT_NOTES section 1), `db/people_add_prod.template.sql` deleted, `docs/night-2026-10-08/` added. No build.

## 6. Before you finish

- `git status` clean on `main`; `ls records/` shows `0004-dev`, `0004-prod`, `0005-dev`, `0005-prod`, `team-2026-10-08`, `roster-2026-10-08`; `git log -- README.md` shows the fifteenth pass.
- Add the real dates to the README's `records/0004-prod-<date>` and `records/0005-prod-<date>` mentions if you ran prod on another day than 8 October (a one-line edit in the next pass is fine).
- Confirm with Arno the roster's defaults (NIGHT_NOTES section 3, items 5 to 8 and 12) before the first real week is planned.
- The heads-up to Yordi: mark in the README whether it was sent.

## 7. If something fails

- A verify FAIL in dev stops the slice: the migration is rerun-safe, so fix forward in the branch and rerun; nothing reaches prod before dev passes.
- A failed build deploys nothing (README, Build and deploy); fix in the branch.
- To roll the web back: README, runbook section 10 (`gcloud run services update-traffic … --to-revisions=<previous>=100`). The migrations are additive (new tables, new functions, the ladder rows) and the old image keeps working on the new database; only step 1.4 changes a person's row.
