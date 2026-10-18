# Deploys of 18 October 2026

The builds, revisions, images and jobs of 18 October 2026 in p4a-cma-prod and p4a-cma-dev, from Martin's
gcloud output of that day; all times UTC. Written down by Claude Code on 18 October 2026 at Martin's request
from his report; the values are his. Ids, counts, dates and times only: no key, no secret and no personal
data. The gcloud output itself is not in this folder.

## Prod builds (trigger `cma-web-main`) and the revisions they made

All six builds `SUCCESS`; each became the `cma-web` revision in prod beside it.

| Build start | SHA | cma-web revision (prod) | Revision created |
|---|---|---|---|
| 03:59:26 | `c2b5c9d` | `cma-web-00070-5rn` | 04:02:06 |
| 06:15:09 | `19fa69f` | `cma-web-00071-bzd` | 06:18:09 |
| 06:29:12 | `607396f` | `cma-web-00072-42g` | 06:31:58 |
| 07:09:30 | `f1cf4db` | `cma-web-00073-h5z` | 07:12:25 |
| 07:51:22 | `1ead2c3` | `cma-web-00074-6lc` | 07:54:14 |
| 09:12:35 | `a6db116` | `cma-web-00075-2hj` | 09:15:53 |

Prod's build list also shows a build at 03:40:46 without a `SHORT_SHA`, status `SUCCESS`.

The commits, by their subject on `main`:

| SHA | Subject |
|---|---|
| `c2b5c9d` | Web security hardening (IT audit of 17 October 2026): a first Content-Security-Policy, IAP's headers stripped after verification, End workday through the guarded route, /api/health answers 503 when misconfigured, verifier fixtures without staff data, a boundaries verifier (`Pulse4all-com/cma#154`) |
| `19fa69f` | Cloud Build (IT audit of 17 October 2026, INFRA-01 and INFRA-02): check-config refuses a bad mode, a missing IAP audience and non-numeric caps; the deploy pins min-instances=1, adds a startup probe on /api/health and the startup CPU boost (`Pulse4all-com/cma#155`) |
| `607396f` | System health (web half, addition 0008r): Configuration → System health with six cards, the documents route, the scheduler's run row, the build's documents copy (`Pulse4all-com/cma#153`) |
| `f1cf4db` | Speed (IT audit, 17 October 2026): identity in one transaction, a warm pool with statement ceilings, roles once per request, a request log line with the database cost, a round-trips budget verifier (`Pulse4all-com/cma#159`) |
| `1ead2c3` | Speed follow-up (IT audit of 17 October 2026, 5.6; prod and dev on f1cf4db): a request line for every request, alert rules in one statement, no prefetch from the frame's links (`Pulse4all-com/cma#165`) |
| `a6db116` | Follow-up snapshot (addition 0008s; IT audit of 17 October 2026, 5.6 continued): figures once a minute per tenant, one data call for the page (`Pulse4all-com/cma#166`) |

## Dev `cma-web`

| Revision | Created | Image |
|---|---|---|
| `cma-web-00034-xqd` | 04:07:56 | the image of prod `cma-web-00070-5rn` (`c2b5c9d`) |
| `cma-web-00035-4qg` | 06:39:18 | the image of prod `cma-web-00072-42g` (`607396f`) |
| `cma-web-00036-w89` | 07:17:19 | the image of prod `cma-web-00073-h5z` (`f1cf4db`) |
| `cma-web-00037-kwj` | 07:20:25 | the image of prod `cma-web-00073-h5z` (`f1cf4db`) |

Dev got no revision on `19fa69f`, `1ead2c3` or `a6db116`. At the end of the day dev's `cma-web` runs
`f1cf4db`, prod's `a6db116`.

## `cma-ingest`

- One new image (digest `sha256:103f771a…`): dev `cma-ingest-00012-nx4` at 03:41:24, prod
  `cma-ingest-00011-wv9` at 03:47:12.
- The ingest jobs (sweep, poll-forms, poll-email, reconcile, backfill, outbox) stay on `ingest:9acbacc` in both
  projects. `9acbacc` on `main` is "Ops: deploy.sh runs from main only, reconcile at 03:30, Dependabot (audit
  5.2-05, DST-01, WEB-10)" (`Pulse4all-com/cma#158`).

## The web image's jobs

- `cma-refresh-follow-up`: new, on `web:a6db116`, every minute; created at 09:17:59 in dev and 09:18:39 in
  prod (`records/0008s-dev-2026-10-18`, `records/0008s-prod-2026-10-18`). In dev it runs a later image than
  dev's `cma-web` (`f1cf4db`).
- `cma-close-forgotten-workdays`: on `web:607396f` in both projects.

## After the records

From Martin's output of 18 October 2026 (UTC), after the builds above:

| Build | Start | SHA | Status | cma-web revision (prod) | Revision created |
|---|---|---|---|---|---|
| `e94fab22` | 13:30:33 | `c98028c` | `SUCCESS` | `cma-web-00076-g6b`, Ready True | 13:33:27 |

`c98028c` on `main` is "UX (IT audit, 17 October 2026): hydration mismatch, nine page keys, focus kept after a
status change, error and not-found pages, "Closed" on the Live board, no CSS all-caps, days-to-correct filter,
dialog names" (`Pulse4all-com/cma#160`). Dev was not deployed with it.

## Not in the report

- The source commit of the new ingest image (`sha256:103f771a…`) and of the 03:40:46 build.
- Why dev got two revisions with one image (`cma-web-00036-w89` and `cma-web-00037-kwj`).
- Whether the ingest jobs should follow the service's image: they stay on `ingest:9acbacc` while the service
  runs the new image.
