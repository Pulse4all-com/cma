/**
 * Desktop only, softened (Decision log, 9 November 2026; amends 4 October 2026). The Workspace is laid out and verified at
 * DESIGN_WIDTH_PX. A window from FIT_FLOOR_PX up to DESIGN_WIDTH_PX gets that same layout, scaled to the window with CSS
 * zoom on the root element (window width / DESIGN_WIDTH_PX); below FIT_FLOOR_PX the gate shows (DesktopOnly); from
 * DESIGN_WIDTH_PX up nothing scales. UI constants, not tenant settings.
 *
 * The one place both numbers are defined. Pure and without imports, so each reader takes them from here: the Tailwind
 * plugin (desktop-fit-css.ts: the gate's and xl's breakpoint, the zoom band, print), the gate's copy (DesktopOnly), the
 * inline script below (layout.tsx) and verify/layout.mjs.
 *
 * Under the zoom, getBoundingClientRect, window.innerWidth and pointer coordinates are in window pixels, while a length set
 * on an element is in its zoomed CSS pixels: code that places an element from a measurement divides by the element's
 * currentCSSZoom (HeaderHint). Viewport units scale with the zoom too, so a modal dialog's limits are percentages of the
 * window (its containing block), never vw or vh. Percentages, sticky and fixed insets need nothing.
 */

/** The width every page is laid out and verified at */
export const DESIGN_WIDTH_PX = 1280;

/** The narrowest window the design width is scaled down to; below it the gate shows */
export const FIT_FLOOR_PX = 1152;

/** The custom property on the root element that holds the zoom; the zoom band in desktop-fit-css.ts reads it */
export const FIT_ZOOM_VAR = "--cma-fit-zoom";

/** The id of the style element the script writes the zoom into */
export const FIT_STYLE_ID = "cma-fit";

/**
 * The blocking inline script in <head> (layout.tsx): it runs while the HTML is parsed, so the first paint is already
 * scaled and nothing waits for hydration. It writes the zoom for the window's width into a style element of its own, and
 * again on every resize: window width / DESIGN_WIDTH_PX, floored to four decimals so the scaled layout is never narrower
 * than the design width; 1 outside the band. A style element and not an attribute on <html>, because React manages the
 * root element's attributes (and resets them on a development remount), while a style element in <head> is left alone.
 * The CSS decides where the zoom applies (on screen, inside the band), so a value the script has not yet updated never
 * reaches print or a window outside the band. Without JavaScript nothing is written and the zoom stays 1: the unscaled
 * layout, or the gate below FIT_FLOOR_PX.
 */
export const FIT_SCRIPT =
  `(function(){var d=document,w=window;if(d.getElementById("${FIT_STYLE_ID}"))return;` +
  `var s=d.createElement("style");s.id="${FIT_STYLE_ID}";d.head.appendChild(s);` +
  `function f(){var x=w.innerWidth,z=x>=${FIT_FLOOR_PX}&&x<${DESIGN_WIDTH_PX}?Math.floor(x*1e4/${DESIGN_WIDTH_PX})/1e4:1;` +
  `s.textContent=":root{${FIT_ZOOM_VAR}:"+z+"}"}` +
  `f();w.addEventListener("resize",f)})()`;
