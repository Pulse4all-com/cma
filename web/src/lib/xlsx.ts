/**
 * A minimal SpreadsheetML (.xlsx) writer (Assets → Pledge lists, addition 0009j): a zip of the workbook's parts, each
 * deflated with node:zlib and checked with its CRC-32, no dependency. It writes what the pledge file needs and nothing
 * else: inline strings and numbers only (never a formula, never a shared string), five cell styles (a bold header,
 * money, a date, a whole number, General), column widths by position, the first row frozen. Every string is
 * XML-escaped and stripped of the control characters XML 1.0 refuses; a number is written as the database gave it
 * (decimal text, never through a float). Deterministic: the same book gives the same bytes, so a frozen quarter file
 * downloads unchanged (each part's time is the book's own date, never the clock).
 *
 * Cells: null (an empty cell), { t: "s", v } a string, { t: "n", v, s } a number as decimal text with its style
 * ("money", "date" for an Excel date serial, "int" for format 0, "general"). The header row's strings are bold.
 */
import { deflateRawSync } from "node:zlib";

export type XlsxNumberStyle = "money" | "date" | "int" | "general";
export type XlsxCell = null | { t: "s"; v: string } | { t: "n"; v: string; s: XlsxNumberStyle };
export interface XlsxSheet {
  /** The tab's name: 1 to 31 characters without [ ] : * ? / \ (the caller cuts and checks it) */
  name: string;
  /** Column widths in characters, by position from column A */
  widths: readonly number[];
  /** The header row's labels (bold, frozen) */
  header: readonly string[];
  rows: readonly (readonly XlsxCell[])[];
}
export interface XlsxBook {
  sheets: readonly XlsxSheet[];
  /** The parts' modification date in the zip (YYYY-MM-DD), so the bytes never depend on the clock */
  date: string;
}

/** The money and date formats of the pledge file, as Excel stores them (custom formats from id 164) */
export const XLSX_FORMATS = { money: '[$€-2]\\ #,##0.00', date: 'dd"-"mm"-"yyyy' } as const;
/** The cell style index of each kind (styles.xml's cellXfs, in this order) */
const STYLE = { plain: 0, header: 1, money: 2, date: 3, int: 4, general: 0 } as const;

/** A string as XML text: the five entities escaped, the control characters XML 1.0 refuses removed */
export function xmlText(value: string): string {
  return value
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

/** A column's letters from its index (0 → A, 25 → Z, 26 → AA) */
export function columnName(index: number): string {
  let n = index + 1;
  let s = "";
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

const NUMBER = /^-?\d{1,15}(\.\d{1,15})?$/;

function cellXml(cell: XlsxCell, ref: string): string {
  if (cell === null) return "";
  if (cell.t === "s") return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${xmlText(cell.v)}</t></is></c>`;
  if (!NUMBER.test(cell.v)) throw new Error(`xlsx: ${ref} is no number`);
  return `<c r="${ref}" s="${STYLE[cell.s]}"><v>${cell.v}</v></c>`;
}

function sheetXml(sheet: XlsxSheet): string {
  const width = Math.max(sheet.header.length, ...sheet.rows.map((r) => r.length), 1);
  const lastRow = sheet.rows.length + 1;
  const header = `<row r="1">${sheet.header.map((h, i) => `<c r="${columnName(i)}1" t="inlineStr" s="${STYLE.header}"><is><t xml:space="preserve">${xmlText(h)}</t></is></c>`).join("")}</row>`;
  const body = sheet.rows.map((r, i) => `<row r="${i + 2}">${r.map((c, j) => cellXml(c, `${columnName(j)}${i + 2}`)).join("")}</row>`).join("");
  const cols = sheet.widths.length
    ? `<cols>${sheet.widths.map((w, i) => `<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`).join("")}</cols>`
    : "";
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<dimension ref="A1:${columnName(width - 1)}${lastRow}"/>`
    + '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
    + '<selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>'
    + '<sheetFormatPr defaultRowHeight="15"/>'
    + cols
    + `<sheetData>${header}${body}</sheetData>`
    + "</worksheet>";
}

function stylesXml(): string {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    + `<numFmts count="2"><numFmt numFmtId="164" formatCode="${xmlText(XLSX_FORMATS.money)}"/><numFmt numFmtId="165" formatCode="${xmlText(XLSX_FORMATS.date)}"/></numFmts>`
    + '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
    + '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
    + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    + '<cellXfs count="5">'
    + '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    + '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    + '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    + '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    + '<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    + "</cellXfs>"
    + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    + "</styleSheet>";
}

function workbookXml(sheets: readonly XlsxSheet[]): string {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<sheets>${sheets.map((s, i) => `<sheet name="${xmlText(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("")}</sheets>`
    + "</workbook>";
}

function partsOf(book: XlsxBook): [string, string][] {
  const n = book.sheets.length;
  const sheetRels = book.sheets.map((_, i) =>
    `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("");
  return [
    ["[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      + '<Default Extension="xml" ContentType="application/xml"/>'
      + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      + book.sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("")
      + "</Types>"],
    ["_rels/.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      + "</Relationships>"],
    ["xl/workbook.xml", workbookXml(book.sheets)],
    ["xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + sheetRels
      + `<Relationship Id="rId${n + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`
      + "</Relationships>"],
    ["xl/styles.xml", stylesXml()],
    ...book.sheets.map((s, i): [string, string] => [`xl/worksheets/sheet${i + 1}.xml`, sheetXml(s)]),
  ];
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let c = i;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

/** CRC-32 (the zip's: polynomial 0xEDB88320) of a buffer */
export function crc32(buf: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) c = (CRC_TABLE[(c ^ (buf[i] ?? 0)) & 0xff] ?? 0) ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A date (YYYY-MM-DD) as the zip's DOS date and a time of 00:00 */
function dosDate(date: string): [number, number] {
  const [y = 1980, m = 1, d = 1] = date.split("-").map(Number);
  return [0, ((Math.max(1980, y) - 1980) << 9) | (m << 5) | d];
}

/** The parts as a zip: each deflated (method 8) with its CRC-32 and sizes, then the central directory */
export function zip(files: readonly [string, Uint8Array][], date: string): Buffer {
  const [time, day] = dosDate(date);
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, data] of files) {
    const nameBuf = Buffer.from(name, "utf8");
    const packed = deflateRawSync(data, { level: 6 });
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(day, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, nameBuf, packed);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(time, 12);
    central.writeUInt16LE(day, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(packed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBuf);
    offset += 30 + nameBuf.length + packed.length;
  }
  const dir = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(dir.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, dir, end]);
}

/** The book as an .xlsx file's bytes */
export function xlsxFile(book: XlsxBook): Buffer {
  if (book.sheets.length === 0) throw new Error("xlsx: a book holds at least one sheet");
  return zip(partsOf(book).map(([name, xml]) => [name, Buffer.from(xml, "utf8")]), book.date);
}
