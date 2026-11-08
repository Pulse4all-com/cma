# cma-web's pool of 10 in prod, 8 November 2026

The two checks before the merge of `Pulse4all-com/cma#244` (cma-web's pool per instance raised from 5 to 10) and the deploy after it (merge `1ffcf4e`), run by Martin on 8 November 2026 in his Terminal. Written down by Claude Code at Martin's request from his report of the runs; the outputs in this folder are his, with the gcloud SDK's SyntaxWarning lines left out. Ids, names, times and outcomes only: no key and no secret.

## Files

| File | What | Verdict |
|---|---|---|
| `trigger.txt` | The substitutions of the trigger `cma-web-main` (`p4a-cma-prod`), before the merge | The trigger sets no `_DB_POOL_MAX` (nor `_AUTH_MODE`, `_MAX_INSTANCES`), so `cloudbuild.yaml`'s defaults apply: 10, `iap`, 4 |
| `dev-env.txt` | The environment of dev's `cma-web` (`p4a-cma-dev`), before the merge | Dev pins `CMA_DB_POOL_MAX=5` on its service; `--image` updates keep it, so dev's `cma-web` stays 2 × 5 = 10 |
| `prod-deploy.txt` | The build of `1ffcf4e` (`d71fb4c9-d07a-4419-ab32-579f82673afa`, `SUCCESS`, created 07:51 Europe/Amsterdam), its `check-config` line, the image and the service's `CMA_DB_POOL_MAX`, after the merge | Prod's `cma-web` runs 4 × 10 since 8 November 2026 |
