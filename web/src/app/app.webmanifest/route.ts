import { config } from "@/lib/config";
import { t } from "@/lib/copy";

export const dynamic = "force-static";

/**
 * The web app manifest (addition 0008z, Welcome on open): an installed Workspace opens on Welcome, so start_url is /.
 * The root layout links it with crossorigin="use-credentials", because behind IAP a manifest fetched without the
 * browser's cookies would be sent to the sign-in page; Next's own manifest file adds that only on a Vercel preview, so
 * this is a plain route. Names from the copy, colours from the style (Sand, Deep Blue); nothing else.
 */
export function GET() {
  const copy = t(config.defaultLocale);
  const manifest = {
    name: copy.app.name,
    short_name: copy.app.name,
    description: copy.app.tagline,
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#FFFDF6",
    theme_color: "#265BA4",
    icons: [{ src: "/icon.png", sizes: "64x64", type: "image/png" }],
  };
  return new Response(JSON.stringify(manifest), { headers: { "content-type": "application/manifest+json; charset=utf-8" } });
}
