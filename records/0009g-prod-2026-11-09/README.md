# Addition 0009g (#254) in prod, 9 November 2026

- main f11d434 (#254); build f11d434 SUCCESS, deployed by Cloud Build. 162 committed (162.txt: INSERT 0 1, COMMIT); 163 not run (dev only).
- The same eleven reruns, each equal to dev: 14, 16, 18, 20, 43, 45 and 47 their two PASS rows; 111 its verdict PASS, no FAIL; 127 32 PASS rows; 07 (ON_ERROR_STOP=0) its seven error lines identical to dev's apart from ids; 27 stops at A4 as in dev (stale, fixed in the PR of these records).
- 07-rerun.txt: block E (marked dev in the script) lists every workday of the tenant with the person's address and hours, which in prod is personal data. Its 1,744 rows are left out of this record, replaced by one line saying so; nothing else in the file is changed. The operator's login is masked as `<operator>` (the additions list), as in #231.

Written down from Martin's report of his own runs on 9 November 2026.
