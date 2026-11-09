# Addition 0009f (#252) in dev, first run, 9 November 2026

- 160 and 161 verified (9 ok). Two reruns failed: 137 A5 "cma.data_quality_of(uuid) jit" (160's create or replace dropped the function's jit = off; fixed in 160 and checked by 161's new S3, see 0009f-dev-2026-11-09) and 117 C4 and C5 (speed on dev's shared core).
