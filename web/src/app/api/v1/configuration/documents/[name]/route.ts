import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { ApiError, dbTraceHeader, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { documentContentType, documentEntry, isDocumentName, parseManifest } from "@/lib/health";

/**
 * GET /api/v1/configuration/documents/<name> (addition 0008r): one of the audit and operations documents
 * the build copied into the image's documents directory, as a download, for tenant.configure holders.
 *
 * The name must be on the allowlist in lib/health AND in the manifest the build wrote: anything else is a
 * 404 before the file system is asked, so there is no traversal and no listing. Markdown and CSV are sent
 * as attachments with a fixed content type and nosniff; never from public/, never rendered as HTML here.
 */
export async function GET(_request: Request, { params }: { params: Promise<{ name: string }> }) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    const { name } = await params;
    const manifest = await readManifest();
    const entry = documentEntry(manifest, name);
    if (!entry || !isDocumentName(name)) throw new ApiError(404, "not_found", "No such document in this build");
    let body: Buffer;
    try {
      body = await readFile(path.join(documentsDir(), entry.name));
    } catch {
      throw new ApiError(404, "not_found", "No such document in this build");
    }
    return new NextResponse(new Uint8Array(body), {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-type": documentContentType(entry.name),
        "content-length": String(body.byteLength),
        "content-disposition": `attachment; filename="${entry.name}"`,
        "x-content-type-options": "nosniff",
        ...dbTraceHeader(),
      },
    });
  });
}

/** documents/ next to the server: /app/documents in the image (Dockerfile), web/documents locally */
function documentsDir(): string {
  return path.join(process.cwd(), "documents");
}

export async function readManifest() {
  try {
    return parseManifest(JSON.parse(await readFile(path.join(documentsDir(), "manifest.json"), "utf8")));
  } catch {
    return null;
  }
}
