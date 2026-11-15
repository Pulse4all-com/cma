import { forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { documentResponse } from "@/lib/documents";

/**
 * GET /api/v1/configuration/documents/<name> (addition 0008r): one of the audit and operations documents
 * the build copied into the image's documents directory, as a download, for tenant.configure holders.
 *
 * The name must be on the allowlist in lib/health AND in the manifest the build wrote: anything else is a
 * 404 before the file system is asked, so there is no traversal and no listing. Markdown and CSV are sent
 * as attachments with a fixed content type and nosniff; never from public/, never rendered as HTML here
 * (lib/documents, which Plan B's route shares since CMA-032).
 */
export async function GET(_request: Request, { params }: { params: Promise<{ name: string }> }) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    const { name } = await params;
    return documentResponse(name, "attachment");
  });
}
