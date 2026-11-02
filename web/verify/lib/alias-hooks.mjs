/** The resolve hook of verify/lib/alias.mjs: "@/x" → src/x(.ts|.tsx|/index.ts); an extensionless relative import in src/ likewise */
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SRC = new URL("../../src/", import.meta.url);
const EXTS = [".ts", ".tsx", "/index.ts"];

function found(base) {
  for (const ext of EXTS) {
    const url = new URL(base + ext);
    if (existsSync(fileURLToPath(url))) return url.href;
  }
  return null;
}

export async function resolve(specifier, context, next) {
  if (specifier.startsWith("@/")) {
    const href = found(new URL(specifier.slice(2), SRC).href);
    if (href) return next(href, context);
  } else if ((specifier.startsWith("./") || specifier.startsWith("../")) && !/\.[cm]?[jt]sx?$/.test(specifier)
             && context.parentURL?.startsWith(SRC.href)) {
    const href = found(new URL(specifier, context.parentURL).href);
    if (href) return next(href, context);
  }
  return next(specifier, context);
}
