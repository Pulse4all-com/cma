# Addition 0009f (#252) in prod, 9 November 2026

- 160 and 161 verified (10 ok). Reruns clean: 113, 123, 133, 137 (24 ok), 139 (16 ok), 149, 159 (D1 now in one snapshot). 69, 73, 75, 101 and 105 are dev-only and refused, writing nothing; 117 does not run in prod.
- In Transit added to Pulse4all Subscriptions' device status catalog (sort order 15).
- 131 part a (131a.txt): the document now from the current take 197.4 ms against 500; serial search 181.7, devices past due 207.5, without subscription reference 238.8 (all against 300); records first page 296.1 (ok) and records page of 50 322.7 (FAIL). The records read computes due items for the whole tenant, so it sits near 300 ms whatever the page size; it loads on demand, after the first paint.
