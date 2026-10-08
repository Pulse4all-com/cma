/**
 * The 1280px gate (README, Roadmap step 2: desktop only). Pure CSS, so there is
 * no flash on first paint and nothing to hydrate. Below 1280px the app is not
 * rendered at all; above it the message is not in the DOM's visible flow. On paper (print media)
 * the gate never applies: the browser lays a print view out at the sheet's width, which is below
 * 1280px for A4, and the roster's print view must still print (found on the first print, 8 October 2026).
 */
import type { ReactNode } from "react";
import type { Copy } from "@/lib/copy";

export function DesktopOnly({ copy, children }: { copy: Copy; children: ReactNode }) {
  return (
    <>
      <div className="hidden h-full desk:block print:block">{children}</div>
      <div
        data-testid="desktop-only"
        className="flex h-full items-center justify-center bg-p4a-sand p-8 desk:hidden print:hidden"
      >
        <div className="max-w-md">
          <h1 className="text-title font-bold text-p4a-heading">{copy.desktopOnly.title}</h1>
          <p className="mt-3 text-body">{copy.desktopOnly.body}</p>
        </div>
      </div>
    </>
  );
}
