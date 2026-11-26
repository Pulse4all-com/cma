import type { NextConfig } from "next";

// Security headers for every response (CSP: the first step below; the nonce step follows).
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "same-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  // The first Content-Security-Policy step (the IT audit of 17 October 2026): no framing, no <base> or
  // form-target hijack, no plugins. The second step (brief N07, WP8, 25 November 2026) is proxy.ts's: on every answer it
  // passes on, its header replaces this one with one policy, script-src with a per-request nonce followed by these four
  // directives (src/lib/csp.ts repeats them; verify:theme checks the one header). This one stays on the answers proxy.ts
  // gives itself or never sees (its 401 and 400, /api/health, static files). The policy allows the desktop fit's inline
  // script in <head> by its sha256; style-src is not set, so the style element the fit writes stays allowed; blocked,
  // verify:layout's fit checks fail
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'" },
];

const nextConfig: NextConfig = {
  // Minimal server for the container image; see Dockerfile. The tracing root is
  // pinned to this folder so the layout of .next/standalone does not depend on
  // what sits above web/ (a parent package.json would otherwise nest it)
  output: "standalone",
  outputFileTracingRoot: import.meta.dirname,
  poweredByHeader: false,
  // No image optimizer: the only images are brand logos, and it removes sharp
  // and the optimizer's attack surface from the runtime image
  images: { unoptimized: true },
  // The Cloud SQL connector stays a real module in the image (as pg already is), so the scheduler's
  // job script (jobs/close-forgotten-workdays.mjs, migration 0005a) can import it from the same
  // node_modules the server uses
  serverExternalPackages: ["@google-cloud/cloud-sql-connector"],
  experimental: {
    // Instant revisits (night N07, decision D4): the client router cache keeps a dynamic page's answer for 30 seconds, so
    // Back, Forward and a second click within that time cost no request; a full prefetch (D5: router.prefetch of kind
    // full, the "static" class) is kept as long, not Next's default 5 minutes, so a prefetched personal page is never
    // older than 30 seconds (to confirm). The cache lives in the tab's memory: per person and per tab, never shared, so the
    // caching rule of 5 November 2026 (no server cache of anything personal) stands. A write the page shows refreshes the
    // router (router.refresh), which drops it; the Live board and the polls keep their own refresh
    staleTimes: { dynamic: 30, static: 30 },
  },
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
