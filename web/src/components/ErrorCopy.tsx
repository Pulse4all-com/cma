"use client";

/**
 * The copy of the error boundary (app/error.tsx), handed down from the root layout as a context. Next
 * renders error.tsx with the error and retry alone, so the boundary cannot be given props, and importing
 * the whole copy module into a client component would ship both languages to every page. The layout
 * knows no person, so this is the tenant's default language, the one the document is in (lang on html).
 */
import { createContext, useContext, type ReactNode } from "react";
import type { Copy } from "@/lib/copy";

export type ErrorPageCopy = Copy["errorPage"];

const ErrorCopyContext = createContext<ErrorPageCopy | null>(null);

export function ErrorCopyProvider({ copy, children }: { copy: ErrorPageCopy; children: ReactNode }) {
  return <ErrorCopyContext.Provider value={copy}>{children}</ErrorCopyContext.Provider>;
}

/** The boundary's copy; null only outside the root layout, which cannot happen for a page */
export function useErrorCopy(): ErrorPageCopy | null {
  return useContext(ErrorCopyContext);
}
