-- CMA data map: schema snapshot (docs/datamap/schema.json)
-- Read-only. Run against a database built from db/ in README order (dev, or a local one):
-- every column of schema cma (tables and views) and cma_read (views), plus the newest migration.
-- Output: one line of JSON. Run with psql -qAt so nothing else is printed.
-- cma_owner, because information_schema only lists columns the session may read.
set role cma_owner;
select json_build_object(
  'generated_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'latest_migration', (select version from cma.schema_migration order by applied_at desc, version desc limit 1),
  'columns', (
    select json_agg(json_build_array(c.table_schema, c.table_name, t.table_type, c.column_name,
             case when c.data_type in ('USER-DEFINED','ARRAY') then c.udt_name else c.data_type end)
           order by c.table_schema, c.table_name, c.ordinal_position)
    from information_schema.columns c
    join information_schema.tables t using (table_schema, table_name)
    where c.table_schema in ('cma', 'cma_read')
  )
);
