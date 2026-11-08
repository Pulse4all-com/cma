# Addition 0009e (#250) in prod, 8 November 2026

- 158 ran after the merge (158.txt). 159's first run (159.txt) read D1 FAIL "pulse4all-subscriptions installed_base FI: keys sources": every row of figures was equal; only the document's `sources` (the sources' live last-read instants) differed, because prod's ingest committed a read between the two documents. 159 run again on its own (159-rerun.txt): 12 ok, 0 FAIL, 0 skip. D1 is to read both documents in one snapshot (follow-up).
- The reruns of 123, 137, 139 and 147: verified, the same counts as before 158.
- The job cma-snapshot-flash on d2779f4 with the schedule cma-snapshot-flash-minutely; cma-snapshot-flash-hourly deleted; the first current take at 15:34 (Europe/Amsterdam).
- 131 part a (131a.txt): PASS, 100 ok, 0 FAIL, 66 skip. The Installed base document now from the current take: 168.5 ms in an earlier run, against 500 ms. The records' first page live sits around its 300 ms budget: 306.6 ms (FAIL) in an earlier run, 283.9 ms in the saved one. The records stream after the first paint and 0009e did not change their read; the Installed base redesign reads them on demand.
- ingest-poll-assets is paused in prod (PROD_RUNBOOK 14.8 still open): the asset register's last read is Fri 6 Nov 09:41.
