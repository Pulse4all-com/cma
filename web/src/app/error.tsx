"use client";

/**
 * The error boundary of every page (the IT audit of 17 October 2026): when a page throws (a read that
 * fails, a database hiccup) a calm card on Sand says what happened and the two next steps, try again
 * (the segment renders again) or go to Welcome, in place of Next's unbranded English page. Nothing of
 * the error itself is shown: Next hands a generic message with a digest, and the digest matches the
 * server log. The copy comes from the root layout (ErrorCopyProvider), in the document's language.
 */
import Link from "next/link";
import { useErrorCopy } from "@/components/ErrorCopy";

export default function ErrorPage({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  const t = useErrorCopy();
  if (!t) return null;
  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <div className="w-full max-w-md rounded-card border border-p4a-border bg-white p-6" data-testid="error-page" role="alert">
        <h1 className="text-title font-bold text-p4a-heading">{t.title}</h1>
        <p className="mt-3 text-body">{t.body}</p>
        <div className="mt-6 flex items-center gap-4">
          <button
            type="button"
            autoFocus
            onClick={() => retry()}
            className="inline-flex h-10 items-center rounded-button bg-p4a-deepblue px-4 font-semibold text-white hover:bg-p4a-denim"
          >
            {t.retry}
          </button>
          <Link href="/" className="font-semibold text-p4a-deepblue hover:underline">
            {t.home}
          </Link>
        </div>
        {error.digest ? <p className="mt-4 text-caption text-p4a-grey tabular">{error.digest}</p> : null}
      </div>
    </div>
  );
}
