import type { Metadata } from "next";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { Keycap } from "@/components/primitives";
import { getIdentity } from "@/lib/auth/identity";
import { config } from "@/lib/config";
import { copy as allCopy, t, type Locale } from "@/lib/copy";
import { data } from "@/lib/data";
import { inviteView } from "@/lib/invitations";
import { switchAccountHref } from "@/lib/logout";
import { NoAccess } from "../../access";

// The link carries the token: never send it on as a referrer, never index the page
export const metadata: Metadata = { title: "Invitation", referrer: "no-referrer", robots: { index: false, follow: false } };

/**
 * /invite/<token> (addition 0008l): behind IAP like every page, for a signed-in account that need not be a
 * person yet (like No access yet). Reading it changes nothing (cma.invitation_preview; a mail scanner may
 * open the link): it shows "Join <workspace>" as <role> with Accept, or why it cannot be accepted
 * (invalid, expired, meant for another address with how to use another account, or a sign-in that
 * already works in another business line, which would lose its access without a tenant picker). A person of that
 * business line goes to Welcome. Accept is a same-origin form post to /invite/accept with the token in the
 * body. The page speaks the invitation's language.
 */
export default async function InvitePage({ params }: { params: Promise<{ token: string }> }) {
  await connection();
  const identity = await getIdentity();
  if (!identity) return <NoAccess copy={t(config.defaultLocale)} />;
  const { token } = await params;
  const preview = await data().previewInvitation(identity, token);
  const view = inviteView(preview, identity.email);
  if (view.kind === "home") redirect("/");
  const locale: Locale = preview.locale && preview.locale in allCopy ? (preview.locale as Locale) : config.defaultLocale;
  const c = t(locale).invite;
  const switchHref = switchAccountHref(config.logoutTarget);

  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <section className="w-full max-w-lg rounded-card border border-p4a-border bg-white p-6" data-testid={`invite-${view.kind}`}>
        {view.kind === "open" ? (
          <>
            <h1 className="text-title font-bold text-p4a-heading">{c.openTitle.replace("{workspace}", view.tenantName)}</h1>
            <p className="mt-3 text-body">{c.openBody.replace("{workspace}", view.tenantName).replace("{role}", view.roleName)}</p>
            <dl className="mt-4 text-small">
              <dt className="text-p4a-muted">{c.signedInAs}</dt>
              <dd className="mt-1 font-semibold text-p4a-body">{identity.email}</dd>
            </dl>
            <form method="post" action="/invite/accept" className="mt-6 flex flex-col gap-3">
              <input type="hidden" name="token" value={token} />
              <button
                type="submit"
                autoFocus
                className="inline-flex h-12 w-fit items-center gap-3 rounded-button bg-p4a-deepblue px-6 font-semibold text-white hover:bg-p4a-denim"
              >
                {c.accept}
                <Keycap>Enter</Keycap>
              </button>
              <p className="text-caption text-p4a-grey">{c.acceptHint}</p>
            </form>
          </>
        ) : view.kind === "wrong_account" ? (
          <>
            <h1 className="text-title font-bold text-p4a-heading">{c.wrongTitle}</h1>
            <p className="mt-3 text-body">{c.wrongBody.replace("{invited}", view.invitedEmail).replace("{current}", view.currentEmail)}</p>
            {switchHref ? (
              <div className="mt-6 flex flex-col gap-2">
                <a
                  href={switchHref}
                  autoFocus
                  className="inline-flex h-12 w-fit items-center rounded-button border border-p4a-deepblue px-6 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue"
                >
                  {c.useAnother}
                </a>
                <p className="text-caption text-p4a-grey">{c.useAnotherThen}</p>
              </div>
            ) : (
              <p className="mt-3 text-body">{c.howToSwitch.replace("{invited}", view.invitedEmail)}</p>
            )}
          </>
        ) : view.kind === "other_tenant" ? (
          <>
            <h1 className="text-title font-bold text-p4a-heading">{c.otherTitle}</h1>
            <p className="mt-3 text-body">{c.otherBody.replace("{workspace}", view.tenantName ?? "")}</p>
          </>
        ) : view.kind === "expired" ? (
          <>
            <h1 className="text-title font-bold text-p4a-heading">{c.expiredTitle}</h1>
            <p className="mt-3 text-body">{view.tenantName ? c.expiredBodyWorkspace.replace("{workspace}", view.tenantName) : c.expiredBody}</p>
          </>
        ) : (
          <>
            <h1 className="text-title font-bold text-p4a-heading">{c.invalidTitle}</h1>
            <p className="mt-3 text-body">{c.invalidBody}</p>
          </>
        )}
      </section>
    </div>
  );
}
