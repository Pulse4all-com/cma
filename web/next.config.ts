import type { NextConfig } from "next";

// Security headers for every response (CSP: the first step below; the nonce step follows).
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "same-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  // The first Content-Security-Policy step (the IT audit of 17 October 2026): no framing, no <base> or
  // form-target hijack, no plugins. It sets no script-src or style-src, so nothing Next.js renders can
  // break on it; a per-request nonce for script-src is the second step (docs/audits/2026-10-17-full-audit)
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
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
