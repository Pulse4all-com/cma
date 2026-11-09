/**
 * The desktop-only gate (README, Roadmap step 2: desktop only; softened on 9 November 2026). Pure CSS, so there is no
 * flash on first paint and nothing to hydrate. The app is laid out at DESIGN_WIDTH_PX; from FIT_FLOOR_PX up to that width
 * it renders the same layout zoomed to the window (src/lib/desktop-fit.ts, the inline script in layout.tsx), and below
 * FIT_FLOOR_PX the app is not rendered at all: the gate says how to make the window wide enough. Above the floor the
 * message is not in the DOM's visible flow. On paper (print media) the gate never applies: the browser lays a print view
 * out at the sheet's width, which is below the floor for A4, and the roster's print view must still print (found on the
 * first print, 8 October 2026). desk is FIT_FLOOR_PX (desktop-fit-css.ts).
 */
import type { ReactNode } from "react";
import type { Copy } from "@/lib/copy";
import { FIT_FLOOR_PX } from "@/lib/desktop-fit";

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
          <p className="mt-3 text-body">{copy.desktopOnly.body.replace("{px}", String(FIT_FLOOR_PX))}</p>
        </div>
      </div>
    </>
  );
}
