import { forPrincipal } from "@/lib/api/respond";
import { documentResponse } from "@/lib/documents";

/** The one document this route serves: never a name from the request */
const PLAN_B_DOCUMENT = "PLAN_B.md";

/**
 * GET /api/v1/plan-b (CMA-032, 15 November 2026): Plan B, what the contact center does when the Workspace is not
 * available (docs/PLAN_B.md), for every person with a role, linked from Welcome. It serves that document only, by a fixed
 * name, from the same build copy and manifest as System health's documents (lib/documents); the other audit documents
 * stay behind tenant.configure there. Shown inline as plain text, never rendered as HTML; a build without the copy says 404
 */
export async function GET() {
  return forPrincipal(async () => documentResponse(PLAN_B_DOCUMENT, "inline"));
}
