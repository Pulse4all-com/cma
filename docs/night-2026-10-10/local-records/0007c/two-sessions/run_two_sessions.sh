#!/bin/bash
# Two concurrent workers on one connection: SKIP LOCKED, no double claim, no waiting.
Q="psql -h /tmp -p 54318 -U martin@pulse4all.com -d ts -X -v ON_ERROR_STOP=1"
echo "== setup: four pending actions (contacts 9000001 to 9000004)"
$Q -q -f setup.sql | grep -v '^$'
echo
echo "== case 1: worker A claims 2 and holds its transaction 4 s; worker B claims up to 50 one second later"
$Q -v name=A -v lim=2 -v hold=4 -f session.sql > a.out 2>&1 &
sleep 1
$Q -v name=B -v lim=50 -v hold=0 -f session.sql > b.out 2>&1
wait
cat a.out b.out | grep -v '^$'
echo "-- after both committed: every action claimed once (attempt 1), all in flight"
$Q -q -f check.sql | grep -v '^$'
echo
echo "== case 2: two more pending (9000005, 9000006); worker C claims all and holds 4 s; worker D claims one second later"
$Q -q -f setup2.sql | grep -v '^$'
$Q -v name=C -v lim=50 -v hold=4 -f session.sql > c.out 2>&1 &
sleep 1
$Q -v name=D -v lim=50 -v hold=0 -f session.sql > d.out 2>&1
wait
cat c.out d.out | grep -v '^$'
echo "-- after both committed"
$Q -q -f check.sql | grep -v '^$'
echo
echo "== case 3: two ingest calls enqueue different values for one contact (9000007) at once; E holds 3 s, F starts one second later"
$Q -v name=E -v country=GB -v hold=3 -f enqueue_session.sql > e.out 2>&1 &
sleep 1
$Q -v name=F -v country=NL -v hold=0 -f enqueue_session.sql > f.out 2>&1
wait
cat e.out f.out | grep -v '^$'
echo "-- after both committed: F waited for E, and E's action is superseded by F's (one pending action for the contact)"
$Q -q -f check.sql | grep -v '^$' | grep -E 'target_id|---|9000007|rows'
