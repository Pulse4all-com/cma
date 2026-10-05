# Verifiers

Verify-by-breaking: every verifier passes on the real app and has a `--provoke`
mode that must fail. Run both when something changes; a verifier that cannot
fail proves nothing.

| Script | Checks | Needs |
|---|---|---|
| `copy.mjs` | Style guide text rules on `src/lib/copy.ts`, all languages | nothing |
| `theme.mjs` | Only palette colours painted, Montserrat only, heading and body colours, Tailwind default palette removed | app in mock mode, `BASE` |
| `layout.mjs` | 1280 and 1920 px shell, gate at 1279, no horizontal scroll, rail and top bar tokens, keycaps; screenshots to `records/layout/` | app in mock mode, `BASE`, `OUT_DIR` optional |
| `iap-token.mjs` | IAP token handling: valid, missing, wrong audience or issuer, expired, future issue, wrong signer, spoofed headers | app in iap mode against the script's key set, see file header |

Browser verifiers use Playwright; install its browser once with
`npx playwright install chromium` (Cloud Shell: add `--with-deps`).

```bash
# app in mock mode on 8080, then:
BASE=http://localhost:8080 npm run verify
BASE=http://localhost:8080 npm run verify:layout -- --provoke   # must fail
```

Record the pass output and the screenshots under `records/<increment>-<env>-<date>`
as the Release flow in the repository README asks.
