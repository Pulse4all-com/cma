/**
 * Verifier: the pledge-list file (Assets → Pledge lists, addition 0009j; D1: exactly the original file's tabs, columns,
 * headers and formats), without a browser, a server or a database: src/lib/pledges.ts builds the book from invented
 * rows (fake lenders, invented serials and customers), src/lib/xlsx.ts writes it, and this script unzips the bytes with
 * node:zlib and reads the parts back.
 *
 *   node --experimental-strip-types verify/pledges.mjs             every check must PASS
 *   node --experimental-strip-types verify/pledges.mjs --provoke   every check must FAIL
 *
 * Checks: the zip (every part, each CRC-32 and size, the same bytes for the same book); the tabs (three per loan by
 * number: main, a, b, the original's names with the loan's device count, a name cut at 31 characters, an apostrophe the
 * cut leaves at the end dropped, a loan without rows absent, no rows no book); each layout's headers verbatim, in each
 * tab's own order; the cells (a string inline, LOAN SPV a number in General, Customer ID a number in format 0 when it
 * is digits only, at most 15, without a leading zero, else text, In Storage text, the amounts money, the dates Excel
 * serials, Months Depriciating format 0, an empty value no cell, never a formula); the formats and widths
 * (styles.xml's money and date formats, the bold header, the widths by position, row 1 frozen); escaping (a label and a
 * serial with & < > " ' and a control character); the file name (prefix, English month, year; _preview; an unsafe
 * prefix replaced).
 */
import { createHash } from "node:crypto";
import { crc32 as nativeCrc32, inflateRawSync } from "node:zlib";
import { crc32, xlsxFile, xmlText } from "../src/lib/xlsx.ts";
import { cellOf, customerCell, dateSerial, H, LAYOUTS, pledgeBook, pledgeFileName, tabName, WIDTHS } from "../src/lib/pledges.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${JSON.stringify(actual).slice(0, 80)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 80)}`}`);
}

/** The zip's entries: { name, data, crcOk, sizeOk } from the central directory, each local entry inflated */
function unzip(buf) {
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd -= 1;
  if (eocd < 0) throw new Error("no end of central directory");
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const out = [];
  for (let i = 0; i < count; i += 1) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error("bad central entry");
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const packed = buf.readUInt32LE(p + 20);
    const size = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extra = buf.readUInt16LE(p + 30);
    const comment = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nameLen).toString("utf8");
    const lName = buf.readUInt16LE(local + 26);
    const lExtra = buf.readUInt16LE(local + 28);
    const start = local + 30 + lName + lExtra;
    const raw = buf.subarray(start, start + packed);
    const data = method === 8 ? inflateRawSync(raw) : raw;
    out.push({ name, data: data.toString("utf8"), crcOk: crc32(data) === crc && buf.readUInt32LE(local) === 0x04034b50, sizeOk: data.length === size, method });
    p += 46 + nameLen + extra + comment;
  }
  return out;
}

// ---- The fixture: invented rows of two loans (layout 1 and 2), every kind of cell -----------------------------------
const row = (o) => ({ valuationDate: "2026-10-01", takenAt: null, loanNumber: 2, lenderLabel: "Lender A", areaLabel: "UK", nameSuffix: "EUR", layout: 1,
  serial: "SN-0001", typeLabel: "HS1", market: "GB", language: "EN", customerId: "C1001", startDate: "2025-08-10", firstShippedOn: "2025-08-09",
  monthsDepreciating: 13, depreciationPerMonth: "5.03", acquisitionValue: "845.00", receipts: "120.00", currentValue: "779.61", ...o });
const ROWS = [
  row({}),
  row({ serial: "SN-0002", customerId: "In Storage", startDate: null }),
  row({ serial: "SN-0003", customerId: "123456789012345", startDate: null }),
  row({ serial: "SN-0004", customerId: "0123", typeLabel: null, depreciationPerMonth: null, acquisitionValue: null, receipts: null, currentValue: null }),
  row({ serial: "SN-0005", customerId: "1234567890123456", language: null, firstShippedOn: null, monthsDepreciating: 0 }),
  row({ loanNumber: 3, lenderLabel: "Lender B", areaLabel: "NL", nameSuffix: "EUR LTD", layout: 2, serial: "SN-0101", market: "NL", language: "NL", customerId: null }),
];
const book = pledgeBook(ROWS, "2026-10-01");
const bytes = xlsxFile(book);
const parts = unzip(bytes);
const part = (name) => parts.find((x) => x.name === name)?.data ?? "";
const WANT_PARTS = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
  ...[1, 2, 3, 4, 5, 6].map((i) => `xl/worksheets/sheet${i}.xml`)];

expect("Z1 the zip: every part, deflated, each CRC-32 and size right",
  [parts.map((x) => x.name), parts.every((x) => x.crcOk && x.sizeOk && x.method === 8)], [WANT_PARTS, true], [[], false]);
// The bytes of this fixed book, pinned: a change of the writer (or of zlib's deflate) that would change a frozen quarter
// file's download fails here first. Update the digest only on a change meant to alter every file's bytes, and say so
const PINNED = process.env.PLEDGES_PRINT_DIGEST ? null : "89a989235497f0de0bdb312a7e6598b3854d2303486ae3e9de9fe49e8fac94aa";
const digest = createHash("sha256").update(bytes).digest("hex");
if (!PINNED) console.log(`digest ${digest}`);
expect("Z3 the fixed book's bytes are the pinned ones (SHA-256); the native CRC-32 the JavaScript one",
  [digest === PINNED, parts.every((x) => nativeCrc32(Buffer.from(x.data, "utf8")) >>> 0 === crc32(Buffer.from(x.data, "utf8")))], [true, true], [false, false]);
expect("Z2 the same book gives the same bytes (a frozen file downloads unchanged)",
  Buffer.compare(bytes, xlsxFile(pledgeBook(ROWS, "2026-10-01"))) === 0 && Buffer.compare(bytes, xlsxFile(pledgeBook(ROWS, "2027-01-01"))) !== 0, true, false);

// ---- Tabs ------------------------------------------------------------------------------------------------------------
const sheetNames = [...part("xl/workbook.xml").matchAll(/<sheet name="([^"]*)"/g)].map((m) => m[1]);
expect("T1 three tabs per loan by number, main then a then b, with the loan's device count",
  sheetNames, ["2) Lender A (5 UK) EUR", "2a) Lender A Movable Assets (5 ", "2b) Lender A Receivables (5 UK)", "3) Lender B (1 NL) EUR LTD",
    "3a) Lender B Movable Assets (1 ", "3b) Lender B Receivables (1 NL)"], []);
const long = { number: 12, lenderLabel: "A Very Long Lender Label Of Sixty Characters At Most Here", areaLabel: "UK", nameSuffix: "EUR", layout: 1 };
// a label of 27 characters ending in an apostrophe: the a-tab's cut at 31 ends on it
const apos = { number: 4, lenderLabel: "Lender ABCDEFGHIJKLMNOPQRS'", areaLabel: "UK", nameSuffix: "EUR", layout: 1 };
expect("T2 a name cut at 31 characters; an apostrophe the cut leaves at the end dropped; 31 at most in every tab",
  [tabName("main", long, 120), tabName("a", apos, 7), tabName("main", apos, 7), tabName("b", { ...apos, lenderLabel: "Lender O'Brien" }, 7),
    sheetNames.every((n) => n.length <= 31)],
  ["12) A Very Long Lender Label Of", "4a) Lender ABCDEFGHIJKLMNOPQRS", "4) Lender ABCDEFGHIJKLMNOPQRS' ", "4b) Lender O'Brien Receivables ", true],
  ["12) A Very Long Lender Label Of Sixty", "4a) Lender ABCDEFGHIJKLMNOPQRS'", "", "", false]);
expect("T3 a loan without rows has no tab; no rows, no book",
  [pledgeBook(ROWS.filter((r) => r.loanNumber === 3), "2026-10-01").sheets.length, pledgeBook([], "2026-10-01")], [3, null], [6, {}]);

// ---- Headers, per tab and layout ------------------------------------------------------------------------------------
const headersOf = (xml) => {
  const first = /<row r="1">(.*?)<\/row>/.exec(xml)?.[1] ?? "";
  return [...first.matchAll(/<t xml:space="preserve">([^<]*)<\/t>/g)].map((m) => m[1].replaceAll("&apos;", "'"));
};
const MAIN = ["SN AED", "Type AED", "Country of location", "Language", "LOAN SPV", "Customer ID", "Acquisition value (in EUR - excl BTW)",
  "Current value (in EUR - excl BTW)", "Depreciation / Month", "Receipts (in EUR - incl BTW)", "Start date"];
const A1 = ["Type AED", "Language", "SN AED", "Country of location", "Acquisition value (in EUR - excl BTW)", "Current value (in EUR - excl BTW)", "LOAN SPV",
  "First Shipment Date", "Months Depriciating", "Depreciation / Month"];
const A2 = ["SN AED", "Type AED", "Country of location", "Language", "LOAN SPV", "First Shipment Date", "Months Depriciating", "Depreciation / Month",
  "Acquisition value (in EUR - excl BTW)", "Current value (in EUR - excl BTW)"];
const B1 = ["SN AED", "Customer ID", "Country of location", "Start date", "Receipts (in EUR - incl BTW)", "Type AED", "Language", "LOAN SPV"];
const B2 = ["SN AED", "Customer ID", "Type AED", "Country of location", "Language", "Receipts (in EUR - incl BTW)", "LOAN SPV", "Start date"];
expect("H1 the main tab's headers verbatim, both layouts",
  [headersOf(part("xl/worksheets/sheet1.xml")), headersOf(part("xl/worksheets/sheet4.xml"))], [MAIN, MAIN], [[], []]);
expect("H2 the a-tab's headers: layout 1 and layout 2, each in its own order (Depriciating as the original writes it)",
  [headersOf(part("xl/worksheets/sheet2.xml")), headersOf(part("xl/worksheets/sheet5.xml"))], [A1, A2], [A2, A1]);
expect("H3 the b-tab's headers: layout 1 and layout 2", [headersOf(part("xl/worksheets/sheet3.xml")), headersOf(part("xl/worksheets/sheet6.xml"))], [B1, B2], [B2, B1]);
expect("H4 the header row bold (style 1), the headers from one table", [/<c r="A1" t="inlineStr" s="1">/.test(part("xl/worksheets/sheet1.xml")),
  LAYOUTS.main.map((c) => H[c])], [true, MAIN], [false, []]);

// ---- Cells ------------------------------------------------------------------------------------------------------------
const sheet1 = part("xl/worksheets/sheet1.xml");
const cell = (xml, ref) => new RegExp(`<c r="${ref}"[^>]*>.*?</c>`).exec(xml)?.[0] ?? null;
expect("C1 SN AED a string inline; LOAN SPV a number in General; the amounts money with their decimal text",
  [cell(sheet1, "A2"), cell(sheet1, "E2"), cell(sheet1, "G2"), cell(sheet1, "H2"), cell(sheet1, "I2"), cell(sheet1, "J2")],
  ['<c r="A2" t="inlineStr"><is><t xml:space="preserve">SN-0001</t></is></c>', '<c r="E2" s="0"><v>2</v></c>', '<c r="G2" s="2"><v>845.00</v></c>',
    '<c r="H2" s="2"><v>779.61</v></c>', '<c r="I2" s="2"><v>5.03</v></c>', '<c r="J2" s="2"><v>120.00</v></c>'], []);
expect("C2 Customer ID: digits a number in format 0 (15 at most, no leading zero), else text; In Storage text",
  [cell(sheet1, "F2"), cell(sheet1, "F3"), cell(sheet1, "F4"), cell(sheet1, "F5"), cell(sheet1, "F6"), customerCell(null), customerCell("0")],
  ['<c r="F2" t="inlineStr"><is><t xml:space="preserve">C1001</t></is></c>', '<c r="F3" t="inlineStr"><is><t xml:space="preserve">In Storage</t></is></c>',
    '<c r="F4" s="4"><v>123456789012345</v></c>', '<c r="F5" t="inlineStr"><is><t xml:space="preserve">0123</t></is></c>',
    '<c r="F6" t="inlineStr"><is><t xml:space="preserve">1234567890123456</t></is></c>', null, { t: "n", v: "0", s: "int" }],
  []);
const sheet2 = part("xl/worksheets/sheet2.xml");
expect("C3 dates as Excel serials in the date style (2025-08-09: 45878, 2026-10-01: 46296); Months Depriciating format 0",
  [cell(sheet1, "K2"), cell(sheet2, "H2"), dateSerial("2026-10-01"), cell(sheet2, "I2")],
  ['<c r="K2" s="3"><v>45879</v></c>', '<c r="H2" s="3"><v>45878</v></c>', 46296, '<c r="I2" s="4"><v>13</v></c>'],
  ['<c r="K2" s="3"><v>2025-08-10</v></c>', null, 0, null]);
expect("C4 an empty value is no cell (no Start date, no model values, no language, no shipment); never a formula",
  [cell(sheet1, "K3"), cell(sheet1, "B5"), cell(sheet1, "G5"), cell(sheet1, "D6"), cell(sheet2, "H6"), cell(sheet2, "I6"),
    parts.some((x) => /<f[ >]/.test(x.data)), cellOf("language", ROWS[4])],
  [null, null, null, null, null, '<c r="I6" s="4"><v>0</v></c>', false, null],
  ['<c r="K3"/>', "", "", "", "", null, true, { t: "s", v: "" }]);

// ---- Formats, widths, the frozen row ----------------------------------------------------------------------------------
const styles = part("xl/styles.xml");
const widths = [...sheet1.matchAll(/<col min="(\d+)" max="\d+" width="([\d.]+)" customWidth="1"\/>/g)].map((m) => Number(m[2]));
expect("F1 the money format [$€-2]\\ #,##0.00 (164) and the date format dd\"-\"mm\"-\"yyyy (165), as styles 2 and 3; 0 is style 4",
  [styles.includes('<numFmt numFmtId="164" formatCode="[$€-2]\\ #,##0.00"/>'), styles.includes('<numFmt numFmtId="165" formatCode="dd&quot;-&quot;mm&quot;-&quot;yyyy"/>'),
    [...styles.matchAll(/<xf numFmtId="(\d+)" fontId="(\d)"[^>]*xfId="0"/g)].map((m) => `${m[1]}/${m[2]}`)],
  [true, true, ["0/0", "0/1", "164/0", "165/0", "1/0"]], [false, false, []]);
expect("F2 the original main tab's widths by position in every tab (A 9.5 … K 17.9); row 1 frozen",
  [widths, [...part("xl/worksheets/sheet3.xml").matchAll(/width="([\d.]+)"/g)].map((m) => Number(m[1])), /<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"\/>/.test(sheet2)],
  [[...WIDTHS], WIDTHS.slice(0, 8), true], [[], [], false]);

// ---- Escaping ------------------------------------------------------------------------------------------------------------
const odd = pledgeBook([row({ lenderLabel: "A&B <Lender> \"Q\" 'x'", serial: "SN<1>&\"'\u0001x", customerId: "In Storage" })], "2026-10-01");
const oddParts = unzip(xlsxFile(odd));
const oddWb = oddParts.find((x) => x.name === "xl/workbook.xml").data;
const oddSheet = oddParts.find((x) => x.name === "xl/worksheets/sheet1.xml").data;
expect("E1 every string XML-escaped (tab names and cells), a control character removed",
  [/<sheet name="2\) A&amp;B &lt;Lender&gt; &quot;Q&quot; &apos;x&apos; \(1/.test(oddWb), cell(oddSheet, "A2"), xmlText("a\u0000b\u000bc\td")],
  [true, '<c r="A2" t="inlineStr"><is><t xml:space="preserve">SN&lt;1&gt;&amp;&quot;&apos;x</t></is></c>', "abc\td"],
  [false, null, "a\u0000b"]);

// ---- The file name --------------------------------------------------------------------------------------------------------
expect("N1 <prefix>_<Month>_<yyyy>.xlsx in English; today's version _preview; an unsafe prefix the default",
  [pledgeFileName("P4A_Pledge_Lists_Maatjes", "2027-01-01", false), pledgeFileName("Pledge_Lists", "2026-11-10", true), pledgeFileName("x y/../", "2026-04-01", false)],
  ["P4A_Pledge_Lists_Maatjes_January_2027.xlsx", "Pledge_Lists_November_2026_preview.xlsx", "Pledge_Lists_April_2026.xlsx"],
  ["P4A_Pledge_Lists_Maatjes_Januari_2027.xlsx", "", "x y/.._April_2026.xlsx"]);

const n = results.length;
const passed = results.filter(Boolean).length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
