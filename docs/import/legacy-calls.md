# Legacy call import (addition 0008zg)

How the outcomes of a former telephony system's calls become legacy call outcomes in the CMA, each matched
to at most one CRM contact, with nothing personal stored or logged. For Pulse4all: Steam's courtesy
completions of 14 May 2025 to 31 August 2026, into Pulse4all Subscriptions (docs/architecture/data-model/0008.md,
Data model: legacy call outcomes; docs/decisions.md, 25 October 2026). Aircall's courtesy calls are not
imported: they stay in the telephony tables and are read through the tag meanings (docs/definitions.md, Tag).

What the job `ingest-import-legacy-calls` does with the file (`ingest/src/jobs/import-legacy-calls.mjs`):

- it reads the file from the private bucket into memory, never onto a disk, and keeps its SHA-256: a second run of
  the same file reuses the batch;
- a row with the marker column filled is the former system's (legacy), an empty one the current system's
  (current); a legacy row dated on or after the cutover, a current row dated before it, a date that does not
  read and a legacy row whose tag text has no mapping are refused and reported by row number (the header is
  row 1);
- a current row is only reconciled: its phone is hashed with the tenant's pepper and the Aircall calls on that
  date with that hash and a current courtesy-completed tag are counted (found or not found); nothing is stored;
- a legacy row is matched to exactly one contact per key: the email (the primary, then the additional emails)
  and the phone (E.164 only, confirmed by the full number); the same contact `email_phone`, one of them `email`
  or `phone`, different contacts `conflict` (left unlinked); neither: the customer id when it has at least
  `--min-customer-id-digits` digits (default 10), first among the store customers the CMA already linked (0008h),
  then in the HubSpot connection's contact ref fields, `customer_id`; otherwise `none`. Unmatched rows are stored
  without a contact;
- it writes every 100 rows, at HubSpot's search pace and above the connection's `api_daily_floor_pct`; a run
  that reaches the floor stops as succeeded with `daily_floor` and the same command later continues;
- the email, phone, names and customer id stay in the job's memory; the log holds counts and row numbers only;
- a row's date is the date the file writes, taken as the tenant's local date (Europe/Amsterdam for Pulse4all, as
  Steam's session export of 0008d was); the reconciliation compares it with the Aircall call's Day in that zone.

Rules for the file: the export stays on your own machine in `~/import`, **never in `~/cma` or the repository**,
and in the bucket only for the run; both copies are deleted afterwards (step 8). The bucket deletes any object
after a day in any case. Real files are prod only; dev uses the synthetic fixture
`ingest/verify/fixtures/legacy-calls/legacy-calls.csv` (invented people).

Before you start:

- `108_legacy_call_outcome.sql` has run in prod, after `109_verify_legacy_call_outcome.sql` passed in dev
  (`18 PASS`, and all 18 `FAIL` provoked);
- the ingest image of this change is deployed with `bash docs/ingest/deploy.sh prod --jobs` (step 2 runs it);
- the tenant's pepper `ingest-hash-pepper-pulse4all-subscriptions` exists (it does since Aircall, B9).

## 1. The bucket (once per project)

A private bucket in europe-west4: uniform access, public access prevention, no soft delete (a deleted object
must be gone, not kept for a week), and every object deleted a day after its upload.

**Terminal** (your own Linux terminal or Cloud Shell, signed in as yourself; any folder)
```bash
gcloud storage buckets create gs://cma-import-p4a-cma-prod --project=p4a-cma-prod --location=europe-west4 \
  --uniform-bucket-level-access --public-access-prevention
```
Expected: `Creating gs://cma-import-p4a-cma-prod/...`.

**Terminal**
```bash
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":1}}]}' > /tmp/cma-import-lifecycle.json
gcloud storage buckets update gs://cma-import-p4a-cma-prod --project=p4a-cma-prod \
  --lifecycle-file=/tmp/cma-import-lifecycle.json --clear-soft-delete
rm /tmp/cma-import-lifecycle.json
```
Expected: `Updating gs://cma-import-p4a-cma-prod/...`.

**Terminal**
```bash
gcloud storage buckets describe gs://cma-import-p4a-cma-prod --project=p4a-cma-prod \
  --format="yaml(location,uniform_bucket_level_access,public_access_prevention,lifecycle_config,soft_delete_policy)"
```
Expected: `location: EUROPE-WEST4`, `uniform_bucket_level_access: true`, `public_access_prevention: enforced`, a
lifecycle rule `Delete` with `age: 1`, and no soft delete retention (`soft_delete_policy` absent or
`retentionDurationSeconds: '0'`).

For a dev rehearsal, the same three blocks with `cma-import-p4a-cma-dev` and `--project=p4a-cma-dev`.

## 2. The job and its read on the bucket

**Terminal** (Cloud Shell, `~/cma` on a clean `main` after the merge)
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected, among the jobs: `storage.objectViewer on gs://cma-import-p4a-cma-prod` (a binding on that bucket only,
for `cma-ingest@p4a-cma-prod.iam.gserviceaccount.com`), the eight jobs deployed, and no schedule for
`ingest-import-legacy-calls`. When the bucket does not exist yet the script says so and grants nothing: run
step 1, then this step again.

## 3. The values for the run

**Studio (cma-prod-pg)**: the HubSpot connection of Pulse4all Subscriptions.
```sql
set role cma_owner;
select c.id, c.name, c.status
from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id
where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot';
reset role;
```
Expected: one row, status `active`. Its id is `--connection`.

**Terminal** (`~/import`, where the export is): the tag texts of the former system's rows, each with its count,
to write `--meanings` exactly as the file holds them (tag texts only, nothing personal).
```bash
python3 - ~/import/steam-courtesy.csv <<'EOF'
import collections, csv, io, sys
raw = open(sys.argv[1], encoding="utf-8-sig").read()
sep = max(";,\t", key=raw.splitlines()[0].count)
rows = csv.DictReader(io.StringIO(raw), delimiter=sep)
for text, n in sorted(collections.Counter(" ".join(r["tags"].split()) for r in rows if r["Inlaaddatum"].strip()).items()):
    print(n, text)
EOF
```
Expected: the three courtesy-completed tag texts with their counts, together 2019.

Pulse4all's arguments (file name as you upload it in step 4):

| Argument | Value |
|---|---|
| `--connection` | the id of the Studio block above |
| `--file` | `gs://cma-import-p4a-cma-prod/steam-courtesy.csv` |
| `--source-system` | `steam` |
| `--cutover` | `2026-09-01` (Aircall's first day for courtesy calls) |
| `--date-format` | `DD-MM-YYYY` (a time after the date is ignored) |
| `--columns` | `tag=tags,date=timestamp call,phone=Phone,email=Email,customer_id=Customer ID,source_marker=Inlaaddatum` |
| `--meanings` | `<positive text>=courtesy_completed_positive;<neutral text>=courtesy_completed_neutral;<negative text>=courtesy_completed_negative` |
| `--min-customer-id-digits` | left out: 10, the Shopify customer ids; the shorter WooCommerce ids and Stripe's `cus_` ids are never looked up (no HubSpot property holds them) |

In `--meanings` each `<… text>` is one line of the Python block's output without its count, exactly as printed
(inner spaces count as one, case counts). A text with no mapping is refused by row number in step 5, so a
missing one shows there. The first name, last name and `Inlaaddatum` columns are never read beyond whether
`Inlaaddatum` is filled.

## 3a. Rehearsal in dev, once (the lookups on a live HubSpot portal)

The phone lookup relies on how HubSpot fills `hs_searchable_calculated_phone_number` and
`hs_searchable_calculated_mobile_number` (the number without its country code), and the additional-email lookup on
how it tokenises `hs_additional_emails`; the job checks that the properties exist, not what they hold. This rehearsal
proves both on the dev portal with invented people, before any real file.

**Browser** (the dev HubSpot portal, Contacts → Create contact; invented people only):
- Fixture Drie, email `fx.three@example.invalid`;
- Fixture Vier, no email, phone number `+31 20 111 0004`;
- Fixture Vijf, email `fx.old@example.invalid`, and on the record a second email `fx.five@example.invalid`.

Expected: three contacts. The run needs the dev tenant's pepper (it exists with Aircall in dev). Then step 1 for
`cma-import-p4a-cma-dev`, `bash docs/ingest/deploy.sh dev --jobs`, and in
**Terminal** (`~/cma`) the fixture into the dev bucket:
```bash
gcloud storage cp ingest/verify/fixtures/legacy-calls/legacy-calls.csv gs://cma-import-p4a-cma-dev/legacy-calls.csv --project=p4a-cma-dev
```
Expected: `Copying file://…`. Then the run of step 6 in dev: `--project=p4a-cma-dev`, `--connection` the dev HubSpot
connection (step 3's Studio block on cma-dev-pg with the dev tenant's slug), `--file gs://cma-import-p4a-cma-dev/legacy-calls.csv`,
`--source-system legacyfixture`, the other values as in the table, and
`--meanings 'Courtesy positief=courtesy_completed_positive;Courtesy neutraal=courtesy_completed_neutral;Courtesy negatief=courtesy_completed_negative'`.
Expected in the finished line: `total` 19, `legacy` 16, `current` 3, `refused` 4 (rows 13 and 14 `cutover`, 15
`unmapped`, 16 `date`), and among the stored rows row 3 `email`, row 4 `phone` and row 5 `email`, with `lookups.phone.one`
and `lookups.email.one` at least 1. Row 4 found by phone proves the searchable phone property; row 5 found by its second
email proves the additional emails. If row 4 or 5 reads `none`, stop and report it: the prod run would miss every
such match. Afterwards the dev batch may be withdrawn (Withdraw a batch, on cma-dev-pg) and the object deleted (step 8
with the dev names).

## 4. Upload

**Terminal** (`~/import`)
```bash
gcloud storage cp ~/import/steam-courtesy.csv gs://cma-import-p4a-cma-prod/steam-courtesy.csv --project=p4a-cma-prod
gcloud storage ls -l gs://cma-import-p4a-cma-prod/
```
Expected: one object, `steam-courtesy.csv`, with the file's size. The bucket deletes it after a day: when the
run is not done by then (a pause, step 6), upload it again; the same file reuses the same batch.

## 5. Dry run

The dry run reads and checks the file, reconciles the current rows and checks that the portal holds the
properties the lookups rely on (`hs_additional_emails`, `hs_searchable_calculated_phone_number`,
`hs_searchable_calculated_mobile_number`, `phone`, `mobilephone`). It searches no contact and writes nothing.

**Terminal** (any folder; the values of step 3 in place of the `<…>`)
```bash
gcloud run jobs execute ingest-import-legacy-calls --project=p4a-cma-prod --region=europe-west4 --wait \
  --args='^|^--connection|<connection id>|--file|gs://cma-import-p4a-cma-prod/steam-courtesy.csv|--source-system|steam|--cutover|2026-09-01|--date-format|DD-MM-YYYY|--columns|tag=tags,date=timestamp call,phone=Phone,email=Email,customer_id=Customer ID,source_marker=Inlaaddatum|--meanings|<positive text>=courtesy_completed_positive;<neutral text>=courtesy_completed_neutral;<negative text>=courtesy_completed_negative|--dry-run'
```
`^|^` makes `|` the separator, because gcloud splits `--args` on commas. Expected: `Execution
[ingest-import-legacy-calls-…] has successfully completed.`

**Terminal**
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-import-legacy-calls" AND jsonPayload.message="import-legacy-calls finished"' \
  --project=p4a-cma-prod --limit=1 --format='json(jsonPayload)'
```
Expected for Pulse4all's file: `"dryRun": true`, `"total": 2144`, `"legacy": 2019`, `"current": 125`,
`"refused": 0`, `"refusedRows": {}`, `"reconciliation": {"found": …, "notFound": …}` (together 125) and
`"failed": 0`. A refused row is listed by number under its reason (`cutover`, `date`, `unmapped`, `label`):
correct `--meanings` or the arguments and run the dry run again. `"error": "property_missing"` with
`missingProperties` means the portal lacks a property the lookups need: stop and report it; the run would
refuse in the same way.

## 6. Run

**Terminal**: the command of step 5 without `|--dry-run` at its end, and with `--async` in place of `--wait`
(the searches take one 400 ms slot each; about an hour for 2019 rows).
```bash
gcloud run jobs execute ingest-import-legacy-calls --project=p4a-cma-prod --region=europe-west4 --async \
  --args='^|^--connection|<connection id>|--file|gs://cma-import-p4a-cma-prod/steam-courtesy.csv|--source-system|steam|--cutover|2026-09-01|--date-format|DD-MM-YYYY|--columns|tag=tags,date=timestamp call,phone=Phone,email=Email,customer_id=Customer ID,source_marker=Inlaaddatum|--meanings|<positive text>=courtesy_completed_positive;<neutral text>=courtesy_completed_neutral;<negative text>=courtesy_completed_negative'
```
Expected: `Execution [ingest-import-legacy-calls-…] is being started`. Progress lines (`import-legacy-calls:
progress`, every 100 rows, the last row number and the lookups so far) appear in the log:

**Terminal**
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-import-legacy-calls" AND jsonPayload.message="import-legacy-calls: progress"' \
  --project=p4a-cma-prod --limit=1 --format='json(jsonPayload.lastRow,jsonPayload.lookups)'
```
Expected within a few minutes: `lastRow` growing, and `lookups.email.one` and `lookups.phone.one` above 0. When the
first lines show many phone or email lookups (`searched`) and none that found anything (`one` and `several` 0), stop
the run (`gcloud run jobs executions cancel <execution> --project=p4a-cma-prod --region=europe-west4`), report it and
withdraw the batch (Withdraw a batch): rows the working key matched are stored as `email` or `phone` and a rerun never
matches them again, though some should read `email_phone` or `conflict`. Once the lookup is fixed, import the file again
(steps 4 to 8). A cancelled execution leaves its run row `running`, so System health shows the job stuck until the next
run of it.

The run ends with the finished line of step 5's logging block: `"batchOutcome": "started"`, the same four counts as
the dry run, `"methods"` (the stored rows per match method: `email_phone`, `email`, `phone`, `customer_id`, `none`,
`conflict`, `forgotten`), `"lookups"`, `"conflictRows"` and `"noneRows"` (row numbers), `"counts"` (what the batch
stores) and `"failed": 0`.

When it ends with `"paused": true, "error": "daily_floor"`, the portal's remaining daily calls fell below the
connection's floor: run the same command after midnight (HubSpot's day); it answers `"batchOutcome":
"reused"`, skips the rows that hold a contact and goes on (the rows without one are looked up again). Keep every
argument as it was: a row stored under another `--meanings` refuses the run (`CMA03`); to change a mapping, withdraw
the batch and import the file again. A run that ends `"failed": 1` with another code
(`rate_limited`, `timeout`, `http_5xx`) has kept what it matched; run the same command again.

While the job runs, System health shows the HubSpot connection's job `legacy_call_import` as running, after 15 minutes
as stuck, and the connection as failing until the run ends; a failed run keeps it failing until a later run of the
same job succeeds. The Workspace has no label for the job yet and shows its key.

## 7. Read the result

**Studio (cma-prod-pg)**
```sql
select b.id, b.source_system, b.cutover_date, b.started_at, b.finished_at, b.withdrawn_at, b.counts
from cma_read.legacy_call_batch b order by b.started_at desc;
```
Expected: one row for `steam`, `finished_at` set, `withdrawn_at` empty, and `counts` with `total` 2144,
`legacy` 2019, `current` 125, `refused` 0, `stored` 2019 and the stored rows per match method (as the finished
line's `methods`).

**Studio (cma-prod-pg)**
```sql
select o.match_method, o.meaning, count(*) as rows, min(o.occurred_on) as first_day, max(o.occurred_on) as last_day
from cma_read.legacy_call_outcome o group by 1, 2 order by 1, 2;
```
Expected: counts only, the days between 2025-05-14 and 2026-08-31, the methods adding up to 2019.

## 8. Delete the file

**Terminal**
```bash
gcloud storage rm gs://cma-import-p4a-cma-prod/steam-courtesy.csv --project=p4a-cma-prod
gcloud storage ls gs://cma-import-p4a-cma-prod/
rm ~/import/steam-courtesy.csv && ls ~/import
```
Expected: `Removing objects:` for the one object, then no output from the listing, and no export left in
`~/import`.

**Browser:** delete every downloaded copy of the export on the laptop (Downloads, and empty the bin).

---

## Withdraw a batch

A withdrawal keeps the rows and leaves them out of every read (`cma_read.legacy_call_outcome`); the batch shows
`withdrawn_at` and who. It is done once; the same file can then be imported again as a new batch (steps 4 to 8).

**Studio (cma-prod-pg)**: the two ids as in docs/import/README.md, step 5; you need `tenant.configure` (admin).
```sql
set role cma_owner;
select t.id as tenant_id, u.id as user_id
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
reset role;
```
Expected: one row.

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.withdraw_legacy_call_batch('<batch id of step 7>');
reset role;
```
Expected: one row of three values, then the time of the withdrawal. A second withdrawal is refused (`CMA03`).

## Privacy

- The file holds names, emails, phone numbers and customer ids. It exists on your machine in `~/import` and, for
  the run, in the private EU bucket; both copies are deleted in step 8, and the bucket deletes any object after a
  day. The bucket admits no public access; it is read by the job's service account (`storage.objectViewer` on this
  bucket) and by whoever holds a storage role on the project (its owners and editors).
- The CMA stores per row the date, the tag meaning, the former system's tag text, the CRM connection and, when one
  contact matched, its id. A contact the CRM later deletes for privacy loses the link (`forgotten`), and a rerun
  never sets it again.
- The job's log holds counts, row numbers and ids of the CMA's own records; never a value of the file.
