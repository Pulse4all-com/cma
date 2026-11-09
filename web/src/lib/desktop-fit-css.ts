/**
 * The CSS side of the desktop fit (desktop-fit.ts), as a Tailwind plugin that globals.css loads with @plugin, so the
 * breakpoints and the zoom band are built from the two constants and never written down twice.
 *
 * - desk: the gate's breakpoint, FIT_FLOOR_PX (DesktopOnly shows the app from it, the gate below it).
 * - xl: lowered to FIT_FLOOR_PX as well. From the floor to the design width the app renders the design width's layout,
 *   zoomed, while media queries keep reading the real window; so every breakpoint at or under the design width must already
 *   hold from the floor to render as it does at DESIGN_WIDTH_PX. sm, md and lg (640 to 1024 px) sit below the floor and
 *   hold anyway; xl sat at 1280 px; 2xl (1536 px) and min-[1800px] sit above the design width and stay off in the band as
 *   they are off at 1280 px. Print lays out at the sheet's width (about 1010 px for A4 landscape), under the floor either way.
 * - The zoom band: on screen from FIT_FLOOR_PX up to the design width, the root element takes the zoom the inline script
 *   wrote; anywhere else, and always on paper, the zoom is 1 (the roster's print view, 8 October 2026).
 */
import plugin from "tailwindcss/plugin";
import { DESIGN_WIDTH_PX, FIT_FLOOR_PX, FIT_ZOOM_VAR } from "./desktop-fit.ts";

const floor = `${FIT_FLOOR_PX / 16}rem`;

export default plugin(
  ({ addBase }) => {
    addBase({
      [`@media screen and (width >= ${FIT_FLOOR_PX}px) and (width < ${DESIGN_WIDTH_PX}px)`]: {
        html: { zoom: `var(${FIT_ZOOM_VAR}, 1)` },
      },
      "@media print": {
        html: { zoom: "1" },
      },
    });
  },
  { theme: { extend: { screens: { desk: floor, xl: floor } } } },
);
