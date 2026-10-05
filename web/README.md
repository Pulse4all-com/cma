# web

The CMA web application. Architecture, scope and decisions live in the repository
README; this file is the developer's quick start.

- Next.js 16 (App Router, Turbopack), TypeScript strict, Tailwind v4 with the
  Pulse4all tokens in `src/app/globals.css`
- Screens import data only from `src/lib/data` and identity only from
  `src/lib/auth/identity`; both have a mock implementation chosen by environment
- All copy in `src/lib/copy.ts`
- Runs as a standalone server in the `Dockerfile`, port 8080

```bash
cp .env.example .env.local
npm ci
npm run dev        # http://localhost:3000
npm run typecheck
npm run build
```
