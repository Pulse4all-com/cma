-- One ingest call: enqueues :country for contact 9000007 and holds its transaction open :hold seconds
\set QUIET on
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'verify-0007c-sessions'), true) \g /dev/null
select set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'verify-0007c-sessions' and u.email = 'ingest@system.invalid'), true) \g /dev/null
\set QUIET off
select clock_timestamp() as started_at \gset
select :'name' as caller, cma.enqueue_contact_writeback((select id from cma.integration_connection where external_account_id = '1000009'),
         '9000007', jsonb_build_object('country', :'country'), null) is not null as enqueued,
       round(extract(epoch from clock_timestamp() - :'started_at'::timestamptz)::numeric, 1) as waited_seconds;
select pg_sleep(:hold) \g /dev/null
commit;
