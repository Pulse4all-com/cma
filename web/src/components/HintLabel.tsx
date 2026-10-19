/**
 * A column header's or a tile's label with its info mark (HeaderHint) after it (19 October 2026): the label's last
 * word and the mark share one span that never wraps, so the mark never stands on a line of its own, while a label
 * of several words still wraps between its words where its column is narrow. No runtime imports and no hooks, so
 * server and client components alike render it.
 */
import type { ReactNode } from "react";

export function HintLabel({ label, children }: { label: ReactNode; children: ReactNode }) {
  if (typeof label !== "string") {
    return <span className="whitespace-nowrap" data-hint-label="">{label}{children}</span>;
  }
  const cut = label.lastIndexOf(" ");
  return (
    <>
      {cut >= 0 ? label.slice(0, cut + 1) : null}
      <span className="whitespace-nowrap" data-hint-label="">{label.slice(cut + 1)}{children}</span>
    </>
  );
}
