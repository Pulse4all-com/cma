/**
 * The configuration screens' field and table classes (docs/style/Pulse4all-Style.md 7.4 and 7.6), in a plain
 * module so a server component (the Sources list) gets the strings themselves: an export of a "use client"
 * module reaches a server component as a client reference, never as its value. shared.tsx re-exports them.
 */
export const field = "h-10 rounded-input border border-p4a-border bg-white px-3 text-body text-p4a-body focus:border-p4a-deepblue";
export const label = "flex flex-col gap-2 text-small font-semibold text-p4a-body";
export const th = "h-10 whitespace-nowrap px-3 text-left font-semibold";
export const td = "border-t border-p4a-border px-3 py-2 align-middle";
/** A body row of a configuration table (docs/style/Pulse4all-Style.md 7.6): at least 40px, zebra rows, a hover row */
export const tr = "h-10 even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";
