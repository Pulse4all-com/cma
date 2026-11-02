/**
 * For a pure verifier that reads a module of src/ which imports others by the app's alias ("@/lib/…", tsconfig's paths):
 * `node --import ./verify/lib/alias.mjs …` resolves "@/x" to src/x.ts (or .tsx, or x/index.ts), as Next resolves it, and
 * an extensionless relative import inside src/ the same way. Nothing else changes: no build, no network.
 */
import { register } from "node:module";

register("./alias-hooks.mjs", import.meta.url);
