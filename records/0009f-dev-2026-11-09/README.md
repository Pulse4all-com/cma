# Addition 0009f (#252) in dev, after the settings fix, 9 November 2026

- 160 run again (INSERT 0 0); 161 verified, 10 ok with S3; every rerun clean, 137 back to 22 ok.
- 117: C5 passes again; C4 fails on its first cold call only (9,233 ms against 7,500; the last five 381 ms), as on 28 October 2026 before 0009e (records/0008zk-dev-2026-10-28). Nothing C4 runs calls what 160 changed; prod's load speed is measured by PROD_RUNBOOK 14.7 (Decision log, 28 October 2026).
- In Transit added to Pulse4all Subscriptions' device status catalog (sort order 15).
