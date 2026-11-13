import { randomUUID } from "node:crypto";
import { Suspense, type ReactNode } from "react";
import { requestDbTrace } from "@/lib/data";
import type { Head } from "@/lib/head-start";

/**
 * A part of a page whose read had a head start (lib/head-start): drawn at once when the read was in by the deadline,
 * else behind its outline in a boundary of its own. The boundary is keyed on what the read is of (k), so another period
 * shows its outline at once instead of holding the old figures on the screen while the new ones are read.
 */
export function Part<T>({ head, k, fallback, children }: { head: Head<T>; k: string; fallback: ReactNode; children: (value: T) => ReactNode }) {
  if (head.ready) return <>{children(head.value)}</>;
  return <Suspense key={k} fallback={fallback}><Late read={head.read}>{children}</Late></Suspense>;
}

async function Late<T>({ read, children }: { read: Promise<T>; children: (value: T) => ReactNode }) {
  return <>{children(await read)}</>;
}

/**
 * The request's whole database cost once every read is over, for verify/round-trips.mjs: the last cma-db meta written
 * is the page's total. Renders nothing unless the trace is on (local verification only: never in iap mode)
 */
export function ReadsTrace({ reads }: { reads: Promise<unknown>[] }) {
  if (requestDbTrace() === null) return null;
  // a boundary of its own on every render (the key): one that was already on the screen would make a click wait for
  // every read before anything of the new page is shown, and the verification would then time another page than prod's
  return <Suspense key={randomUUID()} fallback={null}><TraceAfter reads={reads} /></Suspense>;
}

async function TraceAfter({ reads }: { reads: Promise<unknown>[] }) {
  await Promise.allSettled(reads);
  const dbTrace = requestDbTrace();
  return dbTrace ? <meta name="cma-db" content={dbTrace} /> : null;
}
