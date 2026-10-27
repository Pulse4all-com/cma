# Device import: the asset register's snapshot (addition 0008zi)

How the asset register's CSV export becomes the CMA's read-only mirror of devices and components, which Reports →
Maintenance forecasts from. For Pulse4all Subscriptions the register is the Airtable base "Airtable 2.0" (Pulse4all
Assets, table 2.0 Installed Base), whose rows also carry NetSuite ids (README, Source of truth; Decision log, 27
October 2026). Nothing is written to the register, the CRM or the commerce system. There is no schedule yet: Martin
runs the import by hand (docs/open-decisions.md, when to automate it).

What happens to the export:

- `tools/devices-to-staging.mjs` reads the export with a map (`docs/import/devices-map.example.json`): the map names
  which header feeds which staging column, which headers hold the components (pads, battery) and which hold named ids
  of other systems (the NetSuite ids). Every other header is in the map's `ignore` list and is never read; a header
  the map neither maps nor ignores (a column added to the register) refuses the file. So the customer's names and
  email, which the export holds, never reach the staging file, the database or the terminal. A mapped cell holding an
  @ (an email where an id belongs) is written as a bare @ and counted (`values_with_at`), and the database does the
  same for anything staged another way; the audit log keeps a staged row's keys only.
- The staging file is copied into `cma.device_import_staging` (`docs/import/copy-devices-staging.psql`), then
  `cma.load_device_snapshot(batch, connection, is_full)` loads it: a device per register record (the record id),
  model, status and country mapped through the catalogs' aliases (unmapped: null, and a data-quality finding), the
  customer reference kept only when it is an id, a component whose serial changed recorded as a replacement, devices
  missing from a full snapshot marked as missing, one run (`sync_run`, job `assets_import`), the staged rows deleted.

Rules for the files, as for every import (docs/import/README.md): the export, the map and the staging file stay in
`~/import`, never in `~/cma`, and are deleted after the load (step 9). Real files are prod only; dev uses the synthetic
fixture `tools/fixtures/devices-sample.csv` (The fixture in dev, below).

Before you start: `112` has run, `113` returned `0008zi verified`, and `02` has run again afterwards (the catalogs of
Pulse4all Subscriptions: models HS1 and FRx, pads and battery, the rules, the statuses, the bundling window, the market
aliases). Every database block below is one Terminal run (the `cma_db` helper in
`docs/night-2026-10-10/MORNING_RUNBOOK.md`, Helpers; it prints `connected to cma as <your email>` first), with the
context block as its first lines, so the whole block is one session:

```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'terminal:martin', false);
```

It prints one row of three values; each step's expected output follows it. Replace `<env>` with `dev` or `prod`.

## A. The ids

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v ON_ERROR_STOP=1 <<'SQL'
set role cma_owner;
select t.id as tenant_id, u.id as user_id
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = '<your_email>';
reset role;
SQL
```
Expected: one row. Keep both ids for every block below.

## B. The connection (once per environment)

The register is a connection of kind `assets`; its account id is the base's id, the part of the base's address that
starts with `app` (an identifier, not a secret). There is no secret: the import reads a file.

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v ON_ERROR_STOP=1 <<'SQL'
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'terminal:martin', false);
select connection_id, key from cma.upsert_connection('airtable', 'Airtable 2.0 assets', '<base id>', null, null);
SQL
```
Expected: the context row, then one row with the connection's id and key. Keep the id as `<connection_id>`, then:

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v ON_ERROR_STOP=1 <<'SQL'
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'terminal:martin', false);
select cma.set_connection_kind('<connection_id>', 'assets');
select id, adapter, name, kind, status from cma.integration_connection where id = '<connection_id>';
SQL
```
Expected: the context row, an empty result, then `<connection_id> | airtable | Airtable 2.0 assets | assets | active`.

The contact's link (optional, Configuration → Sources, the HubSpot connection's settings): a setting
`record_url_contact` with `https://{app_host}/contacts/{account}/record/0-1/{id}` links the CRM contact of each device
on Reports → Maintenance; without it the device list shows the contact's id without a link. The register's record id
is shown without a link: the Workspace links to the CRM and the telephony system only (docs/open-decisions.md).

## 1. A folder outside the repository

**Terminal**
```bash
mkdir -p ~/import && chmod 700 ~/import && ls -la ~/import
```
Expected: an empty folder, readable by you only.

## 2. The export

**Browser:** Airtable → base Pulse4all Assets → table 2.0 Installed Base → the grid view with every record → the view's
menu → Download CSV. The file lands in Downloads (Files → Downloads on the Chromebook).

**Terminal**
```bash
mv ~/Downloads/2.0*Installed*Base*.csv ~/import/devices-export.csv && ls -la ~/import
```
(On the Chromebook drag the file from Downloads into Linux files first, then use `~/` instead of `~/Downloads/`.)
Expected: the folder lists `devices-export.csv`. If the glob matches two files, `mv` refuses; leave one.

## 3. The map

**Terminal**
```bash
cp ~/cma/docs/import/devices-map.example.json ~/import/devices-map.json && ls -la ~/import
```
Expected: the folder lists `devices-map.json` too. The example holds the register's headers of 27 October 2026; if the
register has changed, step 5 names the headers it does not know, and you add each to `columns`, `components`,
`external_refs` or `ignore` in `~/import/devices-map.json` (**File**). A header holding a name, an email, a phone
number, an address or free text always goes to `ignore`.

## 4. The date format

The tool never guesses the date format. The export writes each date as the base shows it.

**Browser:** in the base, the column `first_shipment_date_to_customer` of table 2.0 Installed Base: find a date whose day
is above 12. `15/11/2024` (day first) is `dmy`; `11/15/2024` (month first) is `mdy`; `2024-11-15` is `iso`.

Expected: one of the three. Step 5 checks it: a wrong format fails on every date whose day is above 12, so it shows as
many `date_parse_failures`.

## 5. The staging file

**Terminal**
```bash
cd ~/cma && node tools/devices-to-staging.mjs ~/import/devices-export.csv --map ~/import/devices-map.json --date-format dmy --batch assets-<yyyy-mm-dd> --out ~/import/devices-staging.csv
```
Use the format of step 4 and the export's date in the batch key (`assets-2026-10-27`). Expected: `rows` (the records
of the export), `mapped_columns 21`, `ignored_columns 31` (with the example map), `date_parse_failures 0`,
`values_with_at` (the mapped cells holding an @, each written as a bare @; the load counts them as invalid customer
references or dropped references) and the staging file's path. More than a few date failures mean the format is
wrong: run again with the right one. A refusal
(`refused, nothing written`) names the headers or lines: fix the map (step 3) or the export and run again. The tool
prints counts only, never a value.

## 6. Copy the rows in

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v tenant_id=<tenant_id> -v user_id=<user_id> -f ~/cma/docs/import/copy-devices-staging.psql < ~/import/devices-staging.csv
```
Expected: `connected to cma as <your email>`, `BEGIN`, `SET`, one row `t | t | t`, `COPY <n>` with `n` = `rows` of
step 5, one row `assets-<yyyy-mm-dd> | <n> | <n>`, `COMMIT`. On an error nothing is kept (one transaction).

## 7. Load

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v ON_ERROR_STOP=1 <<'SQL'
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'terminal:martin', false);
select jsonb_pretty(cma.load_device_snapshot('assets-<yyyy-mm-dd>', '<connection_id>', true)) as counts;
SQL
```
Expected: the counts. `rows` = step 6's `n`; on the first load `inserted` = `rows`; on a later one `inserted` (new
records), `updated` (changed ones), `unchanged`, `missing_now` (devices the register no longer holds),
`components_replaced` (a pads or battery serial that changed); `unmapped_model`, `unmapped_status` and
`unmapped_market` (records whose label the catalogs do not know, such as the export's Spain and Italy in a catalog
without ES and IT: dev holds both since 27 October 2026; in prod check Configuration → Markets before the first real
load, add a missing market and run seed `02` again for its alias), `customer_ref_invalid` (a customer reference that
is no id; it is never stored) and `refs_dropped` (a serial or id that is no id, left out). A refusal (`CMA02`,
`CMA04`, `CMA06`) writes nothing and says why, naming the export's line. `true` is a full snapshot: every record of
the register is in the file. A partial file (a filtered view) is loaded with `false`, so nothing is marked missing.

## 8. Read the result

**Browser:** Reports → Maintenance: the Past due bucket and the months, per market and model, Planned exchanges and
Components; a cell opens the device list. Reports → Data quality: the asset register's eight checks (devices without a
serial, a serial held twice, an unmapped model, status or country, a customer reference that is no id, due items
without a due date, devices in the field without a subscription reference).

Write the counts of step 7, the batch key and the time (no ids of devices or customers) down as
`records/0008zi-import-<env>-<yyyy-mm-dd>/load.txt`, from the values Martin reports.

## 9. Delete the files

**Terminal**
```bash
rm -rf ~/import && ls ~/import
```
Expected: `ls: cannot access '/home/…/import': No such file or directory`. Also delete the export from Downloads on the
Chromebook and empty the bin.

---

## The fixture in dev

`tools/fixtures/devices-sample.csv` is synthetic: 30 records with fake serials, ids and `example.invalid` addresses in
the ignored columns, covering every data-quality check. Steps A and B as above in dev, then instead of steps 1 to 5:

**Terminal**
```bash
cd ~/cma && node tools/devices-to-staging.mjs tools/fixtures/devices-sample.csv --map docs/import/devices-map.example.json --date-format dmy --batch fixture-1 --out /tmp/devices-staging-1.csv
```
Expected: `rows 30`, `mapped_columns 21`, `ignored_columns 31`, `date_parse_failures 0`, `values_with_at 1` (a customer
id that is an address), the path. Then steps 6 and 7 with `/tmp/devices-staging-1.csv` and the batch `fixture-1`.
Expected counts with the seed's catalogs and a market catalog that holds ES and IT, as dev does (27 October 2026):
`rows 30`, `inserted 30`, `updated 0`, `unchanged 0`, `missing_now 0`, `components_replaced 0`, `unmapped_model 1`,
`unmapped_status 1`, `unmapped_market 0` (2 in a catalog without ES and IT: the fixture's Spain and Italy),
`customer_ref_invalid 1`, `refs_dropped 0`.

The rerun: the same two commands with `fixture-2` (and `/tmp/devices-staging-2.csv`). Expected: `rows 30`,
`inserted 0`, `updated 0`, `unchanged 30`, the other counts as before. Then `rm /tmp/devices-staging-*.csv`.

Reports → Maintenance in October 2026, from October for 12 months, every tracked device (27: the three in Returned,
Stolen/Missing and Decommissioned are not forecast): Past due holds 5 due items in 4 planned exchanges (NL FRx 2 with
one end of life, DE HS1 1, AT HS1 1), the months hold 28 due items in 23 planned exchanges, and 4 items have no due
date (NL HS1 2, NL unknown model 2). From November the October items move to Past due. Reports → Data quality:
`component_due_unknown 4`, `device_customer_ref_invalid 1`, `device_market_unmapped 0` (2 without ES and IT),
`device_model_unmapped 1`, `device_serial_duplicate 2`, `device_serial_missing 1`, `device_status_unmapped 1`,
`field_device_without_subscription_ref 1`.

### Before the merge

The page itself cannot be looked at in dev before the merge: the web cannot run locally against dev under a personal
login. Its database client (`web/src/lib/db/client.ts`) applies no `CMA_DB_SET_ROLE`, and a personal login holds
`cma_app` without inheritance, so a local web gets "permission denied for schema cma" (docs/open-decisions.md). Read
the same figures in Studio instead, as the application and as the dev seed's admin (`admin@example.com`, who holds
every report permission in Pulse4all Subscriptions; docs/RUNBOOK.md, 7. Database work):

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select set_config('app.tenant_id', t.id::text, false),
       set_config('app.user_id', u.id::text, false),
       set_config('app.actor_label', 'studio:martin', false)
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = 'admin@example.com';
set role cma_app;
with p as (select cma.maintenance_page('2026-10-01', 12, null, null, null) as j),
     c as (select x from p, jsonb_array_elements(p.j -> 'cells') x)
select (p.j ->> 'devices')::integer as devices,
       (select sum((x ->> 'component_items')::integer + (x ->> 'end_of_life')::integer) from c where x ->> 'bucket' = 'past_due') as past_due_items,
       (select sum((x ->> 'exchanges')::integer) from c where x ->> 'bucket' = 'past_due') as past_due_exchanges,
       (select sum((x ->> 'component_items')::integer + (x ->> 'end_of_life')::integer) from c where x ->> 'bucket' <> 'past_due') as month_items,
       (select sum((x ->> 'exchanges')::integer) from c where x ->> 'bucket' <> 'past_due') as month_exchanges,
       (p.j ->> 'unknown_items')::integer as unknown_items,
       (select string_agg(m, ', ' order by m) from jsonb_array_elements_text(p.j -> 'filter_markets') m) as markets
from p;
select check_key, total from cma.data_quality()
where check_key in (select check_key from cma.data_quality_assets_checks())
order by check_key;
reset role;
```
Expected (October 2026; from a later month use its first day, and the October items move to past due): the context
row; then one row: `devices 27`, `past_due_items 5`, `past_due_exchanges 4`, `month_items 28`, `month_exchanges 23`,
`unknown_items 4`, `markets AT, BE, DE, DK, ES, FI, FR, GB, IE, IT, NL, NO, SE`; then eight rows:
`component_due_unknown 4`, `device_customer_ref_invalid 1`, `device_market_unmapped 0`, `device_model_unmapped 1`,
`device_serial_duplicate 2`, `device_serial_missing 1`, `device_status_unmapped 1`,
`field_device_without_subscription_ref 1`.

The on-screen check of Reports → Maintenance, its grid, a figure's device list and its file, happens in dev's
`cma-web` after the merge, with prod's image (docs/RUNBOOK.md, 4. Try a new image in dev first), as the test user
`admin`.

## A later snapshot

Each later export is a batch of its own: steps 1 to 9 with the export's date as the key. The same file loaded twice
reports every record as unchanged. A refused load writes nothing but leaves the batch's staged rows of step 6; a second
copy under the same key would double them (and the load then refuses every record id as appearing twice). Discard them
first, then copy again:

**Terminal**
```bash
cma_db <env> && psql "$PGCONN" -X -v ON_ERROR_STOP=1 <<'SQL'
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'terminal:martin', false);
delete from cma.device_import_row where batch_key = 'assets-<yyyy-mm-dd>';
SQL
```
Expected: the context row, then `DELETE <n>` with the rows of step 6.

## What the load and the forecast decide

- **Model, status, market:** a label maps to the catalog row whose key or alias it is, ignoring case and spaces at
  the ends (`cma.device_model_key_of`, `cma.device_status_key_of`); the country maps through the market aliases or a
  code (`cma.market_code_of`). A new label is configuration: add it as an alias (Studio, the catalog's `aliases`).
- **Tracked:** only devices whose status is tracked (`is_tracked`) are forecast; Reports → Maintenance shows the field
  (`is_in_field`) and the stock (`is_in_stock`) apart. A status name never decides anything.
- **Due date:** a component's recorded expiry, else the anchor date plus the rule's interval for the model, else none
  (basis unknown). The anchor is the day a later snapshot first showed the component's new serial when it replaced
  another (a replacement restarts the rule), else the last shipment, else the first; the components of the first load
  keep the shipment. The anchor is the day of the load, not of the swap, so loading often keeps it close.
  **Action date:** the due date less the rule's lead days (Pulse4all: 60). A device's end of life is a due item of its
  own, on the recorded date, without lead days. **Past due:** the action date lies before the current month.
- **Planned exchange:** a device's due items whose action dates lie within `assets.bundle_window_days` (Pulse4all: 90)
  of the earliest one are one exchange, counted in the month of that earliest action date.
