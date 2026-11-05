import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";
import { DesktopOnly } from "@/components/DesktopOnly";
import { ErrorCopyProvider } from "@/components/ErrorCopy";

// Montserrat is the only typeface (style guide 3.1). The variable font ships with the app, so no request leaves the
// browser for fonts. Since night N06 (5 November 2026) it is a woff2 subset of the Latin ranges the Workspace's
// languages and markets use (106 kB in place of the 745 kB TTF; the weight axis 100 to 900 kept; made with
// pyftsubset, docs/night-2026-11-06/NIGHT_NOTES.md), preloaded by next/font with font-display swap.
const montserrat = localFont({
  src: "../fonts/Montserrat-VF.woff2",
  variable: "--font-montserrat",
  weight: "100 900",
  display: "swap",
});

const copy = t(config.defaultLocale);

export const metadata: Metadata = {
  title: { default: copy.app.name, template: `%s · ${copy.app.name}` },
  description: copy.app.tagline,
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang={config.defaultLocale} className={`${montserrat.variable} h-full antialiased`}>
      <body className="h-full font-sans text-body text-p4a-body">
        {/* The manifest opens an installed Workspace on Welcome (addition 0008z); with credentials, so IAP lets it through */}
        <link rel="manifest" href="/app.webmanifest" crossOrigin="use-credentials" />
        {/* The error boundary's words (app/error.tsx) travel as a context: Next gives the boundary no props */}
        <ErrorCopyProvider copy={copy.errorPage}>
          <DesktopOnly copy={copy}>{children}</DesktopOnly>
        </ErrorCopyProvider>
      </body>
    </html>
  );
}
