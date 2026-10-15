/**
 * Shared by every page: resolve who is here and whether they may work.
 * Returns the principal, or the No access yet page to render instead.
 */
import type { ReactNode } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { getAccess, type Identity, type Principal } from "@/lib/auth/identity";
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

export function NoAccess({ copy, identity = null, switchHref = null }: { copy: Copy; identity?: Identity | null; switchHref?: string | null }) {
  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <div className="max-w-md">
        <h1 className="text-title font-bold text-p4a-heading">{copy.noAccess.title}</h1>
        <p className="mt-3 text-body">{copy.noAccess.body}</p>
        <p className="mt-2 text-body">{copy.noAccess.next}</p>
        {identity ? (
          // The person's own sign-in id, the value Add a person asks for; shown to its owner only
          <dl className="mt-6 rounded-card border border-p4a-border bg-white p-4 text-small">
            <dt className="text-p4a-muted">{copy.noAccess.accountLabel}</dt>
            <dd className="mt-1 font-semibold text-p4a-body">{identity.email}</dd>
            <dt className="mt-3 text-p4a-muted">{copy.noAccess.idLabel}</dt>
            <dd className="tabular mt-1 select-all font-semibold text-p4a-body" data-testid="account-id">{identity.subject}</dd>
            <dd className="mt-2 text-caption text-p4a-grey">{copy.noAccess.idHint}</dd>
          </dl>
        ) : null}
        {switchHref ? (
          // Only with the signed-out page in place (CMA_LOGOUT_TARGET=signed-out): IAP clears its cookie and
          // the browser lands outside IAP, where Log in shows Google's account chooser and Add another account
          // opens Google's add-account form in a new tab (it does not return here by itself)
          <a href={switchHref} className="mt-6 inline-flex font-semibold text-p4a-deepblue underline" data-testid="no-access-switch">
            {copy.noAccess.useAnother}
          </a>
        ) : null}
      </div>
    </div>
  );
}
