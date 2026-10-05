# web

The CMA web application. Architecture, scope and decisions live in the repository
README; this file is the developer's quick start.

- Next.js 16 (App Router, Turbopack), TypeScript strict, Tailwind v4 with the
  Pulse4all tokens in `src/app/globals.css`
- Screens import data only from `src/lib/data` and identity only from
  `src/lib/auth/identity`; both have a mock implementation chosen by environment
- All copy in `src/lib/copy.ts`
- Identity: `src/proxy.ts` verifies IAP's token (`src/lib/auth/iap.ts`) and hands the
  identity to the app in headers only it can set; `CMA_AUTH_MODE=mock` substitutes the
  test identity. The app_user check is `findPrincipal` on the data interface
- Runs as a standalone server in the `Dockerfile`, port 8080
- `verify/` holds the verify-by-breaking scripts; see each file's header

```bash
cp .env.example .env.local
npm ci
npm run dev        # http://localhost:3000
npm run typecheck
npm run build
```
