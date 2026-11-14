import type { Copy } from "@/lib/copy";
import { Badge } from "./primitives";

/**
 * A definition's status as a badge: Proposed (for Kira to confirm) or Pending (an open question, named in the hint).
 * In a file of its own with no client imports (13 November 2026), so a page that shows only the badge (the placeholder
 * pages) does not take Customers → Active's client parts with it; ActiveParts re-exports it
 */
export function StatusBadge({ status, copy }: { status: "Proposed" | "Pending" | "Decided"; copy: Pick<Copy, "flash"> }) {
  return <Badge tone={status === "Decided" ? "success" : status === "Proposed" ? "info" : "warning"}>{copy.flash[`status_${status}`]}</Badge>;
}
