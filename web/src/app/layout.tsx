import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";
import { DesktopOnly } from "@/components/DesktopOnly";

// Montserrat is the only typeface (style guide 3.1). The variable font ships
// with the app, so no request leaves the browser for fonts.
const montserrat = localFont({
  src: "../fonts/Montserrat-VF.ttf",
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
        <DesktopOnly copy={copy}>{children}</DesktopOnly>
      </body>
    </html>
  );
}
