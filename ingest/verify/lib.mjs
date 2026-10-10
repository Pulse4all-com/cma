/**
 * The verifiers' harness, as in web/verify: expect(name, actual, expected, provoked). Normal runs
 * compare with expected and must all PASS; --provoke compares with a wrong value and every check
 * must FAIL, which proves each check can fail.
 */
export const PROVOKE = process.argv.includes("--provoke");
const results = [];

export function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  const shown = (v) => String(v === undefined ? "undefined" : JSON.stringify(v)).slice(0, 70);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${shown(actual)}${pass ? "" : `, wanted ${shown(want)}`}`);
  return pass;
}

/** Prints the verdict line and sets the exit code. */
export function verdict() {
  const passed = results.filter(Boolean).length;
  const n = results.length;
  if (PROVOKE) {
    const ok = passed === 0;
    console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
    process.exitCode = ok ? 0 : 1;
  } else {
    const ok = passed === n;
    console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
    process.exitCode = ok ? 0 : 1;
  }
}
