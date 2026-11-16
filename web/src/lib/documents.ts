import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { ApiError, dbTraceHeader } from "@/lib/api/respond";
import { documentContentType, documentEntry, isDocumentName, parseManifest } from "@/lib/health";

/**
 * The documents the build copied into the image (addition 0008r): the directory, its manifest and one document as a
 * response. One route serves them: Configuration → System health's (every name on the allowlist, tenant.configure; Plan
 * B's route of CMA-032 was removed on 15 November 2026). A name must be on the allowlist in lib/health AND in the
 * manifest the build wrote: anything else is a 404 before the file system is asked, so there is no traversal and no
 * listing; never from public/, never rendered as HTML.
 */

/** documents/ next to the server: /app/documents in the image (Dockerfile), web/documents locally */
function documentsDir(): string {
  return path.join(process.cwd(), "documents");
}

/** The manifest the build wrote, or null without one */
export async function readManifest() {
  try {
    return parseManifest(JSON.parse(await readFile(path.join(documentsDir(), "manifest.json"), "utf8")));
  } catch {
    return null;
  }
}

/** One document as a private response: an attachment with its fixed type, nosniff and no-store */
export async function documentResponse(name: string): Promise<NextResponse> {
  const entry = documentEntry(await readManifest(), name);
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
}
