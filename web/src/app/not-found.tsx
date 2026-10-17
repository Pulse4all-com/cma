import Link from "next/link";
import { getAccess } from "@/lib/auth/identity";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";

/**
 * The page for an address that is no page (the IT audit of 17 October 2026): a calm card on Sand with
 * the way back to Welcome, in place of Next's unbranded English page. The language is the person's own
 * when they are signed in and known, as on every page; the tenant default otherwise (the layout's).
 * Nothing is read beyond who is asking.
 */
export default async function NotFound() {
  const access = await getAccess().catch(() => null);
  const copy = t(access?.kind === "granted" ? access.principal.locale : config.defaultLocale);
  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <div className="w-full max-w-md rounded-card border border-p4a-border bg-white p-6" data-testid="not-found-page">
        <h1 className="text-title font-bold text-p4a-heading">{copy.notFound.title}</h1>
        <p className="mt-3 text-body">{copy.notFound.body}</p>
        <Link href="/" className="mt-6 inline-flex h-10 items-center rounded-button bg-p4a-deepblue px-4 font-semibold text-white hover:bg-p4a-denim">
          {copy.notFound.home}
        </Link>
      </div>
    </div>
  );
}
