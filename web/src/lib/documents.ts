import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { ApiError, dbTraceHeader } from "@/lib/api/respond";
import { documentContentType, documentEntry, isDocumentName, parseManifest } from "@/lib/health";

/**
 * The documents the build copied into the image (addition 0008r): the directory, its manifest and one document as a
 * response. Two routes serve them: Configuration → System health's (every name on the allowlist, tenant.configure) and,
 * since CMA-032, Plan B's (PLAN_B.md alone, every person with a role). A name must be on the allowlist in lib/health AND
 * in the manifest the build wrote: anything else is a 404 before the file system is asked, so there is no traversal and
 * no listing; never from public/, never rendered as HTML.
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

/**
 * One document as a private response: an attachment with its fixed type (System health), or inline as plain text, which
 * a browser shows as it is and never renders (Plan B); nosniff and no-store either way
 */
export async function documentResponse(name: string, disposition: "attachment" | "inline"): Promise<NextResponse> {
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
      "content-type": disposition === "inline" ? "text/plain; charset=utf-8" : documentContentType(entry.name),
      "content-length": String(body.byteLength),
      "content-disposition": `${disposition}; filename="${entry.name}"`,
      "x-content-type-options": "nosniff",
      ...dbTraceHeader(),
    },
  });
}
