#!/bin/bash
# EXPLAIN (ANALYZE, BUFFERS) of every page function in cma_perf as the web login with the tenant context,
# nested statements included (auto_explain, loaded as postgres before SET ROLE; RLS applies to the web login).
OUT=/home/user/cma/local-records/5.3-database/plans
T=01a14ac1-8b06-7f8a-ac30-8849132389aa
MGR=01a14ac1-8b63-7af0-87ba-8e70178a5517
AGT=01a14ac1-8b63-7b13-b169-1683e04580f8
MON=$(date -d "last monday" +%F 2>/dev/null); [ "$(date +%u)" = "1" ] && MON=$(date +%F)
run() { # name user sql
  local name=$1 user=$2 sql=$3
  {
    echo "load 'auto_explain';"
    echo "set auto_explain.log_min_duration = 1; set auto_explain.log_analyze = on; set auto_explain.log_buffers = on;"
    echo "set auto_explain.log_nested_statements = on; set auto_explain.log_timing = on; set auto_explain.log_format = 'text';"
    echo "set client_min_messages = log;"
    echo "set role \"cma-web@local.iam\";"
    echo "\\timing on"
    for pass in warm measured; do
      echo "begin;"
      echo "select set_config('app.tenant_id', '$T', true), set_config('app.user_id', '$user', true), set_config('app.actor_label', '', true);"
      echo "-- $pass pass"
      echo "$sql"
      echo "rollback;"
    done
  } > /var/tmp/5.3/plans/$name.sql
  psql -h 127.0.0.1 -U postgres -d cma_perf -X -f /var/tmp/5.3/plans/$name.sql > $OUT/$name.txt 2>&1
  # the measured pass: the last top-level LOG duration line that quotes our statement, and the row count
  local dur=$(grep -n 'LOG:  duration' $OUT/$name.txt | tail -n +1 | awk -F'duration: ' '{print $2}' | awk '{print $1}' | tail -1)
  local rows=$(grep -E '^\([0-9]+ rows?\)' $OUT/$name.txt | tail -1)
  printf "%-28s top-level-last-ms=%-10s %s\n" "$name" "$dur" "$rows"
}
run team_now               $MGR "select * from cma.team_now();"
run team_hours_30d         $MGR "select * from cma.team_hours(current_date - 30, current_date, null);"
run team_status_time_30d   $MGR "select * from cma.team_status_time(current_date - 30, current_date, null);"
run calls_overview_30d     $MGR "select * from cma.calls_overview(current_date - 30, current_date, null, null, 'day');"
run calls_overview_7d      $MGR "select * from cma.calls_overview(current_date - 7, current_date, null, null, 'day');"
run calls_per_person_30d   $MGR "select * from cma.calls_per_person(current_date - 30, current_date, null, null);"
run inbound_service_30d    $MGR "select * from cma.inbound_service(current_date - 30, current_date, 'day');"
run inbound_today          $MGR "select * from cma.inbound_today();"
run missed_callbacks       $MGR "select * from cma.missed_callbacks();"
run speed_to_lead_30d      $MGR "select * from cma.speed_to_lead_summary(current_date - 30, current_date, 'day');"
run speed_to_lead_7d       $MGR "select * from cma.speed_to_lead_summary(current_date - 7, current_date, 'day');"
run intake_per_day_30d     $MGR "select * from cma.intake_per_day(current_date - 30, current_date);"
run follow_up_summary      $MGR "select * from cma.follow_up_summary();"
run follow_up_by_owner     $MGR "select * from cma.follow_up_by_owner();"
run open_leads             $MGR "select count(*) from cma.open_leads();"
run open_tickets           $MGR "select count(*) from cma.open_tickets();"
run open_tasks             $MGR "select count(*) from cma.open_tasks();"
run data_quality           $MGR "select * from cma.data_quality();"
run sources                $MGR "select * from cma.sources();"
run forms_report_30d       $MGR "select * from cma.forms_report(current_date - 30, current_date, 'day', null, null, null);"
run telephony_history_start $MGR "select * from cma.telephony_history_start();"
run my_messages_mgr        $MGR "select count(*) from cma.my_messages(null, 50);"
run my_unread_count_mgr    $MGR "select * from cma.my_unread_count();"
run my_profile_mgr         $MGR "select * from cma.my_profile();"
run roster_week            $MGR "select * from cma.roster_week('$MON', 'nl');"
run roster_entries         $MGR "select count(*) from cma.roster_entries('$MON', 'nl');"
run roster_weeks           $MGR "select * from cma.roster_weeks('nl', '$MON'::date - 28, '$MON'::date + 7);"
run roster_today           $MGR "select count(*) from cma.roster_today();"
run team_people            $MGR "select count(*) from cma.team_people();"
run own_day_agent          $AGT "select s.business_date, s.status, s.started_at, s.ended_at, ws.key as status_key, ws.name as status_name, coalesce(c.closed_seconds, 0)::int as closed_seconds, c.running_since, c.status_since, cma.business_day_end(s.business_date, s.timezone) as day_ends_at from cma.workday_summary s left join cma.work_status ws on ws.tenant_id = cma.current_tenant_id() and ws.id = s.current_status_id left join lateral (select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds, max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped) as running_since, max(i.from_at) filter (where i.is_open and not i.is_capped) as status_since from cma.time_interval i join cma.work_status iws on iws.tenant_id = cma.current_tenant_id() and iws.id = i.status_id where i.workday_id = s.workday_id) c on true where s.user_id = cma.current_user_id() and s.business_date = cma.business_date(now(), cma.user_timezone(cma.current_user_id()));"
run own_days_30d_agent     $AGT "select s.business_date, s.status, s.started_at, s.ended_at, s.working_seconds, coalesce((select sum(i.seconds) from cma.time_interval i join cma.work_status ws on ws.tenant_id = cma.current_tenant_id() and ws.id = i.status_id where i.workday_id = s.workday_id and not ws.is_working), 0)::bigint as pause_seconds from cma.workday_summary s where s.user_id = cma.current_user_id() and s.business_date between current_date - 30 and current_date order by s.business_date;"
run my_roster_agent        $AGT "select count(*) from cma.my_roster(current_date - 7, current_date + 7);"
run my_messages_agent      $AGT "select count(*) from cma.my_messages(null, 50);"
run my_unread_count_agent  $AGT "select * from cma.my_unread_count();"
run my_follow_up_agent     $AGT "select * from cma.my_follow_up();"
run open_workday_agent     $AGT "select (cma.open_workday()).status;"
