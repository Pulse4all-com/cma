/**
 * Shared by every page: resolve who is here and whether they may work.
 * Returns the principal, or the No access yet page to render instead.
 */
import type { ReactNode } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { getAccess, type Principal } from "@/lib/auth/identity";
import { config } from "@/lib/config";
import { t, type Copy } from "@/lib/copy";

export type Resolved =
  | { ok: true; me: Principal; copy: Copy }
  | { ok: false; page: ReactNode };

export async function resolve(): Promise<Resolved> {
  // Identity is per request; never prerender a page that depends on it
  await connection();
  const access = await getAccess();
  const copy = t(config.defaultLocale);
  if (!access) {
    // Behind IAP this cannot happen; without a verified identity we show nothing
    return { ok: false, page: <NoAccess copy={copy} /> };
  }
  if (access.kind === "no_access") redirect("/no-access");
  return { ok: true, me: access.principal, copy: t(access.principal.locale) };
}

export function NoAccess({ copy }: { copy: Copy }) {
  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <div className="max-w-md">
        <h1 className="text-title font-bold text-p4a-heading">{copy.noAccess.title}</h1>
        <p className="mt-3 text-body">{copy.noAccess.body}</p>
        <p className="mt-2 text-body">{copy.noAccess.next}</p>
      </div>
    </div>
  );
}
