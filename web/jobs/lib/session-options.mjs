/**
 * Database session settings sent at connect (brief N07, WP5; decision D6 of 24 November 2026): CMA_DB_SESSION_OPTIONS
 * holds name=value pairs separated by ";" (or ","; cloudbuild.yaml passes ";", since a comma splits --set-env-vars), empty
 * by default, which the web's pool and the web jobs' pools send
 * as the connection's startup options (pg's `options`, "-c name=value"), as they send statement_timeout today. Martin
 * switches each on after measuring it in dev (MORNING_RUNBOOK of night N07).
 *
 * Only planner and memory settings named below are accepted, each with its own value rule: never role, search_path,
 * app.tenant_id or any security setting (a default app.tenant_id would make row-level security answer for that
 * tenant). A name or value outside the rules throws at pool creation, so a typo fails loudly instead of being ignored.
 */

/** The settings that may be sent, each with the values it accepts */
export const SESSION_OPTION_RULES = Object.freeze({
  jit: /^(on|off)$/,
  work_mem: /^[1-9][0-9]{0,3}(kB|MB)$/,
  random_page_cost: /^(0|[1-9][0-9]?)(\.[0-9]{1,2})?$/,
});

/**
 * Parses CMA_DB_SESSION_OPTIONS. Answers { pairs: [[name, value], ...], options: "-c name=value ..." or undefined }.
 * Throws an Error naming the bad entry (never its value beyond the rule) when a name or value is not allowed.
 * @param {string | undefined | null} raw
 * @returns {{ pairs: [string, string][], options: string | undefined }}
 */
export function parseSessionOptions(raw) {
  const text = (raw ?? '').trim();
  if (!text) return { pairs: [], options: undefined };
  const seen = new Set();
  /** @type {[string, string][]} */
  const pairs = [];
  for (const part of text.split(/[;,]/)) {
    const entry = part.trim();
    if (!entry) continue;
    const eq = entry.indexOf('=');
    if (eq <= 0) throw new Error(`CMA_DB_SESSION_OPTIONS: "${entry.slice(0, 40)}" is not name=value`);
    const name = entry.slice(0, eq).trim().toLowerCase();
    const value = entry.slice(eq + 1).trim();
    const rule = Object.prototype.hasOwnProperty.call(SESSION_OPTION_RULES, name) ? SESSION_OPTION_RULES[name] : null;
    if (!rule) throw new Error(`CMA_DB_SESSION_OPTIONS: ${name.slice(0, 40)} is not an allowed setting (allowed: ${Object.keys(SESSION_OPTION_RULES).join(', ')})`);
    if (!rule.test(value)) throw new Error(`CMA_DB_SESSION_OPTIONS: the value of ${name} is not allowed`);
    if (seen.has(name)) throw new Error(`CMA_DB_SESSION_OPTIONS: ${name} is given twice`);
    seen.add(name);
    pairs.push([name, value]);
  }
  if (pairs.length === 0) return { pairs: [], options: undefined };
  return { pairs, options: pairs.map(([n, v]) => `-c ${n}=${v}`).join(' ') };
}

/** The pool options to spread into a pg.Pool's configuration: { options } when any is set, else {} */
export function sessionPoolOptions(env = process.env) {
  const { options } = parseSessionOptions(env.CMA_DB_SESSION_OPTIONS);
  return options ? { options } : {};
}
