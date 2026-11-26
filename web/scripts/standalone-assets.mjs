/**
 * postbuild (26 November 2026, Martin): puts .next/static and public next to the standalone server, as the Dockerfile's run
 * stage does, so `npm start` (node .next/standalone/server.js) serves the CSS, the scripts, the fonts and the icons
 * locally too. Without them every page answers 200 while every asset answers 404, and the browser verifiers fail on a
 * page without its styles (the desktop-only gate shows, the frame does not hold, a verify:layout run times out). In the
 * image the Dockerfile copies the same two folders again over these, so the image holds the same files.
 */
import { cpSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");
const standalone = join(root, ".next", "standalone");
if (!existsSync(standalone)) {
  console.log("standalone assets: no .next/standalone (not a standalone build), nothing copied");
  process.exit(0);
}
for (const [from, to] of [[join(root, ".next", "static"), join(standalone, ".next", "static")], [join(root, "public"), join(standalone, "public")]]) {
  if (!existsSync(from)) continue;
  // a previous build's files go first, so an asset the new build dropped is not served on
  rmSync(to, { recursive: true, force: true });
  cpSync(from, to, { recursive: true });
}
console.log("standalone assets: .next/static and public copied next to .next/standalone/server.js");
