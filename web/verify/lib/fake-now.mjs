/**
 * A fake clock for the verifiers (backlog CMA-113, 15 November 2026): with CMA_FAKE_NOW set to an instant
 * (`2026-12-01T09:00:00+01:00`), `new Date()` and `Date.now()` start at that instant and run on from it at the real
 * pace, so the mock data's "today" and every period preset can be tried on the 1st, the 15th or the last day of a month.
 * A Date built from a value is untouched. Without CMA_FAKE_NOW nothing changes. Test only: the app never imports it.
 *
 *   CMA_FAKE_NOW=2026-12-01T09:00:00+01:00 node --import ./verify/lib/fake-now.mjs verify/<name>.mjs
 *   CMA_FAKE_NOW=… NODE_OPTIONS="--import ./verify/lib/fake-now.mjs" npm run verify:<name>
 *   CMA_FAKE_NOW=… NODE_OPTIONS="--import $PWD/verify/lib/fake-now.mjs" CMA_AUTH_MODE=mock CMA_DATA_MODE=mock node .next/standalone/server.js
 *
 * The browser keeps its own clock: a browser verifier against a server started this way reads the server's "today" in
 * what the pages render, and its own `new Date()` (theme.mjs and hints.mjs build a few dates themselves) from the real
 * clock unless it runs under the same preload.
 */
const fake = process.env.CMA_FAKE_NOW;
if (fake) {
  const Real = Date;
  const offset = Real.parse(fake) - Real.now();
  if (Number.isNaN(offset)) throw new Error(`CMA_FAKE_NOW is not an instant: ${fake}`);
  const now = () => Real.now() + offset;
  // a function rather than a subclass, so Date() called without new answers as the real one does (a string of now)
  function FakeDate(...args) {
    if (!new.target) return new Real(now()).toString();
    return args.length === 0 ? new Real(now()) : new Real(...args);
  }
  FakeDate.prototype = Real.prototype;
  FakeDate.now = now;
  FakeDate.parse = Real.parse;
  FakeDate.UTC = Real.UTC;
  globalThis.Date = FakeDate;
  if (process.env.CMA_FAKE_NOW_QUIET !== "1") console.error(`fake-now: the clock reads ${new Date().toISOString()}`);
}
