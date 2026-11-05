#!/usr/bin/env node
/**
 * An HTML-table export to one CSV per ISO week (addition 0008d, docs/import/README.md, A weekly
 * batch, step 1b).
 *
 *   node tools/legacy-export-html-to-csv.mjs <export.xls> --out <dir> [options]
 *
 * Steam Connect's "LogIn/Out" export arrives as an HTML <table> in a file named .xls. This writes the
 * table's rows as CSV, one file per ISO week of the login date: <dir>/<prefix>-w<ww>.csv
 * (steam-export-w44.csv), each with the table's header and that week's rows in the export's order.
 * Each file is the export of step 4 of a weekly batch (tools/legacy-sessions-to-staging.mjs). Plain
 * Node, no dependencies.
 *
 *   --col-login    Ingelogd      the login column; the date it starts with decides the week
 *   --date-format  d-m-yyyy      that date (tokens d dd m mm yyyy); the time after it is not read
 *                                here (step 4 reads and checks it)
 *   --prefix       steam-export  the files' name before -w<ww>.csv
 *
 * Rules: the header row is the first row of the table's <thead>; every other row of the table whose
 * cell count differs from the header's (Steam's footer "# Records: n") is dropped and counted as
 * rows_dropped_footer. A cell's text is its content without tags, HTML entities decoded, trimmed.
 * The file is read in the charset its byte order mark or its <meta> names, else UTF-8. The CSV is
 * RFC 4180: commas, a cell quoted when it holds a comma, a quote or a line end; LF line ends.
 *
 * Refuses (exit 1, nothing written) a file without a <table>, a table without a header row in
 * <thead>, a header without the login column, a login that does not parse (the table rows named),
 * a table without a row of the header's width, a file that does not read in its charset, and an
 * export whose weeks of two ISO years would write the same file. Prints per file the path and its
 * rows, then rows_read and rows_dropped_footer; never a cell.
 */
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dateParser } from "./legacy-sessions-to-staging.mjs";

export const DEFAULT_LOGIN_COLUMN = "Ingelogd";
export const DEFAULT_DATE_FORMAT = "d-m-yyyy";
export const DEFAULT_PREFIX = "steam-export";

// ---- reading the file -----------------------------------------------------------------------

/**
 * The file's bytes as text: the charset of its byte order mark, else of its <meta> (charset= in the
 * first 4 KB), else UTF-8. Bytes that do not read in that charset refuse the file.
 */
export function decodeExport(bytes) {
  let label = "utf-8";
  if (bytes[0] === 0xff && bytes[1] === 0xfe) label = "utf-16le";
  else if (bytes[0] === 0xfe && bytes[1] === 0xff) label = "utf-16be";
  else if (!(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf)) {
    const head = Buffer.from(bytes.subarray(0, 4096)).toString("latin1");
    const m = /<meta\b[^>]*?charset\s*=\s*["']?\s*([a-z0-9_.:-]+)/i.exec(head);
    // a <meta> that names UTF-16 in a file without its byte order mark reads as UTF-8 (HTML's rule)
    if (m && !/^utf-16/i.test(m[1])) label = m[1].toLowerCase();
  }
  let decoder;
  try { decoder = new TextDecoder(label, { fatal: true }); } catch { return { text: null, problem: `the file names a charset this tool does not know (${label})` }; }
  try { return { text: decoder.decode(bytes), problem: null }; } catch { return { text: null, problem: `the file does not read as ${label}` }; }
}

const LATIN1 = ("nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute "
  + "micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil "
  + "Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute "
  + "Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute "
  + "icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml").split(" ");
const ENTITIES = {
  amp: 38, lt: 60, gt: 62, quot: 34, apos: 39,
  ...Object.fromEntries(LATIN1.map((name, i) => [name, 160 + i])),
  OElig: 338, oelig: 339, Scaron: 352, scaron: 353, Yuml: 376, fnof: 402, circ: 710, tilde: 732,
  ndash: 8211, mdash: 8212, lsquo: 8216, rsquo: 8217, sbquo: 8218, ldquo: 8220, rdquo: 8221, bdquo: 8222,
  dagger: 8224, Dagger: 8225, bull: 8226, hellip: 8230, permil: 8240, lsaquo: 8249, rsaquo: 8250, euro: 8364, trade: 8482,
};

/** HTML entities decoded: named (HTML 4's set), decimal and hexadecimal; an unknown name stays as written */
export function decodeEntities(text) {
  return text.replace(/&(?:#x([0-9a-f]+)|#([0-9]+)|([a-z][a-z0-9]*));/gi, (whole, hex, dec, name) => {
    if (name !== undefined) return Object.hasOwn(ENTITIES, name) ? String.fromCodePoint(ENTITIES[name]) : whole;
    const cp = hex !== undefined ? parseInt(hex, 16) : Number(dec);
    return cp > 0 && cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff) ? String.fromCodePoint(cp) : "�";
  });
}

/** A cell's text: its content without tags, entities decoded, trimmed (as the browser's textContent, trimmed) */
export function cellText(raw) {
  return decodeEntities(raw.replace(/<[^>]*>/g, "")).trim();
}

/**
 * The first <table> of the HTML as rows: [{ head, cells }], head true for a row inside <thead>.
 * Closing tags that HTML lets a file leave out (</td>, </th>, </tr>, </thead>, </tbody>) may be
 * missing; comments are skipped.
 */
export function readTable(html) {
  const s = html.replace(/<!--[\s\S]*?-->/g, "");
  const open = /<table\b[^>]*>/i.exec(s);
  if (!open) return null;
  const from = open.index + open[0].length;
  const end = s.slice(from).search(/<\/table\s*>/i);
  const body = end < 0 ? s.slice(from) : s.slice(from, from + end);

  const rows = [];
  let inHead = false;
  let row = null;
  let cell = null;
  let at = 0;
  const finishCell = () => { if (cell !== null) { row.cells.push(cellText(cell)); cell = null; } };
  const finishRow = () => { finishCell(); if (row) { rows.push(row); row = null; } };
  for (const m of body.matchAll(/<(\/?)(thead|tbody|tfoot|tr|th|td)\b[^>]*>/gi)) {
    if (cell !== null) cell += body.slice(at, m.index);
    at = m.index + m[0].length;
    const closing = m[1] === "/";
    const tag = m[2].toLowerCase();
    if (tag === "td" || tag === "th") {
      finishCell();
      if (!closing) {
        if (!row) row = { head: inHead, cells: [] };
        cell = "";
      }
    } else if (tag === "tr") {
      finishRow();
      if (!closing) row = { head: inHead, cells: [] };
    } else {
      finishRow();
      inHead = !closing && tag === "thead";
    }
  }
  if (cell !== null) cell += body.slice(at);
  finishRow();
  return rows;
}

// ---- weeks ----------------------------------------------------------------------------------

/** The ISO year and week of a date "yyyy-mm-dd" */
export function isoWeek(date) {
  const [y, m, d] = date.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7)); // the Thursday of its week decides the year
  const year = t.getUTCFullYear();
  return { year, week: Math.floor((t - Date.UTC(year, 0, 1)) / 604_800_000) + 1 };
}

const csvCell = (v) => (/[",\r\n]/.test(v) ? `"${v.replaceAll('"', '""')}"` : v);
const csvText = (rows) => rows.map((r) => r.map(csvCell).join(",")).join("\n") + "\n";

/**
 * The export's text to one CSV per ISO week of the login date. Pure: no file access.
 * options: { loginColumn, dateFormat, prefix }
 * Returns { problems, files: [{ name, year, week, rows, text }], counts: { rows_read, rows_dropped_footer } }.
 */
export function splitByWeek(html, options = {}) {
  const loginColumn = options.loginColumn ?? DEFAULT_LOGIN_COLUMN;
  const format = options.dateFormat ?? DEFAULT_DATE_FORMAT;
  const prefix = options.prefix ?? DEFAULT_PREFIX;
  const refuse = (...problems) => ({ problems, files: [], counts: null });

  const table = readTable(html);
  if (!table) return refuse("the file holds no <table>");
  const headerAt = table.findIndex((r) => r.head && r.cells.length > 0);
  if (headerAt < 0) return refuse("the table has no header row in <thead>");
  const header = table[headerAt].cells;
  const login = header.indexOf(loginColumn);
  if (login < 0) return refuse(`the header has no column "${loginColumn}" (the login)`);

  const parse = dateParser(format);
  const tokens = format.trim().split(/\s+/).length;
  const weeks = new Map();
  const problems = [];
  let read = 0;
  let dropped = 0;
  table.forEach((r, i) => {
    if (i === headerAt) return;
    read++;
    if (r.cells.length !== header.length) { dropped++; return; }
    const date = parse(r.cells[login].split(/\s+/).slice(0, tokens).join(" "))?.slice(0, 10);
    if (!date) { problems.push(`table row ${i + 1}: the login does not read as ${format}`); return; }
    const { year, week } = isoWeek(date);
    const key = `${year}-W${String(week).padStart(2, "0")}`;
    if (!weeks.has(key)) weeks.set(key, { year, week, rows: [] });
    weeks.get(key).rows.push(r.cells);
  });
  if (problems.length) return refuse(...problems);
  if (weeks.size === 0) return refuse(`the table holds no row of the header's ${header.length} cells`);

  const files = [...weeks.entries()].sort(([a], [b]) => a.localeCompare(b))
    .map(([, w]) => ({ ...w, name: `${prefix}-w${String(w.week).padStart(2, "0")}.csv`, text: csvText([header, ...w.rows]) }));
  const names = new Map();
  for (const f of files) {
    const other = names.get(f.name);
    if (other) problems.push(`ISO weeks ${other.year}-W${String(other.week).padStart(2, "0")} and ${f.year}-W${String(f.week).padStart(2, "0")} would both write ${f.name}: export one year at a time`);
    else names.set(f.name, f);
  }
  if (problems.length) return refuse(...problems);
  return { problems: [], files, counts: { rows_read: read, rows_dropped_footer: dropped } };
}

// ---- the command ----------------------------------------------------------------------------

const OPTIONS = new Set(["out", "col-login", "date-format", "prefix"]);
const USAGE = "usage: legacy-export-html-to-csv.mjs <export.xls> --out <dir> [--col-login <name>] [--date-format <d-m-yyyy>] [--prefix <name>]";

export function main(argv) {
  const o = { files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { o.files.push(a); continue; }
    if (!OPTIONS.has(a.slice(2)) || i + 1 >= argv.length) { console.error(USAGE); return 2; }
    o[a.slice(2)] = argv[++i];
  }
  const [exportPath] = o.files;
  if (!exportPath || o.files.length > 1 || !o.out) { console.error(USAGE); return 2; }
  if (o.prefix !== undefined && !/^[A-Za-z0-9_-]{1,64}$/.test(o.prefix)) {
    console.error("the prefix is letters, digits, - and _, at most 64");
    return 2;
  }
  let isDir = false;
  try { isDir = statSync(o.out).isDirectory(); } catch { /* reported below */ }
  if (!isDir) { console.error(`the output folder ${o.out} does not exist`); return 2; }

  let bytes;
  try { bytes = readFileSync(exportPath); } catch { console.error(`the export ${exportPath} cannot be read`); return 2; }
  const { text, problem } = decodeExport(bytes);
  const result = problem ? { problems: [problem] }
    : splitByWeek(text, { loginColumn: o["col-login"], dateFormat: o["date-format"], prefix: o.prefix });
  if (result.problems.length) {
    console.error(`refused, nothing written: ${result.problems.length} problem(s)`);
    for (const p of result.problems.slice(0, 20)) console.error(`  ${p}`);
    if (result.problems.length > 20) console.error(`  … and ${result.problems.length - 20} more`);
    return 1;
  }
  const paths = result.files.map((f) => join(o.out, f.name));
  result.files.forEach((f, i) => writeFileSync(paths[i], f.text));
  result.files.forEach((f, i) => console.log(`${paths[i]}  ${f.rows.length} rows`));
  for (const [k, v] of Object.entries(result.counts)) console.log(`${k.padEnd(28)} ${v}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
