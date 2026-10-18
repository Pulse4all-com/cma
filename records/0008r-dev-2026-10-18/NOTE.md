# Note on this folder

77.txt is db/77_verify_audit_hardening.sql (0008q) from main, run because this branch predates 0008q and holds no db/77; it checks that 0008r's new functions are closed to PUBLIC and pin their search path.
78 ran with PGOPTIONS='-c lock_timeout=5s' (the script sets none; sync_run is written every minute).

Written down from Martin's own runs on 18 October 2026.
