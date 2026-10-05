import type { NextConfig } from "next";

// Security headers for every response. CSP comes with the first real data screen.
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "same-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
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
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
