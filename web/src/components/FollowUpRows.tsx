"use client";

/**
 * The body of a Follow-up table (addition 0008s): the rows arrive as short display cells, formatted on the server
 * (FollowUpTables), and are drawn here with the table's classes. The page refreshes every 10 seconds, and a server-
 * drawn body sent every cell's markup again with each refresh (about 1.9 kB per row); the cells are a fraction of it.
 * The markup is the same as before: docs/style/Pulse4all-Style.md 7.6 (rows of at least 40 px, zebra rows, a hover row).
 */
import { Badge, type BadgeTone } from "./primitives";
import { RecordLink } from "./RecordLink";

/**
 * A cell: text; nothing; { m } Muted text; { e } text in the error colour; { b, v } a badge; { v, tag } text with a
 * badge after it; { u, l } the record link (u null: none), l its accessible name
 */
export type Cell =
  | string
  | null
  | { m: string }
  | { e: string }
  | { b: BadgeTone; v: string }
  | { v: string; tag: [BadgeTone, string] }
  | { u: string | null; l: string };

export interface CellRow {
  /** The row's key: the record's id */
  k: string;
  c: Cell[];
}

const td = "h-10 whitespace-nowrap px-3";
const tr = "border-b border-p4a-border last:border-b-0 odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

function CellContent({ cell }: { cell: Cell }) {
  if (cell === null || typeof cell === "string") return <>{cell}</>;
  if ("m" in cell) return <span className="text-p4a-muted">{cell.m}</span>;
  if ("e" in cell) return <span className="text-p4a-error">{cell.e}</span>;
  if ("b" in cell) return <Badge tone={cell.b}>{cell.v}</Badge>;
  if ("tag" in cell) return <>{cell.v}<span className="ml-2"><Badge tone={cell.tag[0]}>{cell.tag[1]}</Badge></span></>;
  return <RecordLink url={cell.u} label={cell.l} />;
}

/** columns: each column's extra classes (alignment, weight, tabular figures) */
export function FollowUpRows({ columns, rows }: { columns: string[]; rows: CellRow[] }) {
  return (
    <tbody>
      {rows.map((r) => (
        <tr key={r.k} className={tr}>
          {r.c.map((cell, i) => (
            <td key={i} className={columns[i] ? `${td} ${columns[i]}` : td}>
              <CellContent cell={cell} />
            </td>
          ))}
        </tr>
      ))}
    </tbody>
  );
}
