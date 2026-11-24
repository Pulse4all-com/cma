/**
 * A page's part of the frame (night N07, decision D2): the breadcrumbs, the content's width and the page. The frame itself
 * (the top bar, the rail, main) is ShellFrame, rendered once by the route group's layout (app/(shell)/layout.tsx), so a
 * click between two pages re-renders this part alone and the frame never blinks. A page keeps calling Shell with what it
 * knows of itself: `active` and `activeHref` name it for the breadcrumbs (the rail's current item follows the address on
 * the client), `wide` its width and `trail` the crumbs it appends.
 *
 * Breadcrumbs (16 October 2026): caption size in Footnote Grey, a 16 px chevron between the crumbs, the last crumb Inkt
 * semi-bold with aria-current and never a link. Welcome shows none. A crumb to a bare rail page (Welcome; Messages on
 * Send a message) closes the open group, as the rail's own link does (NavBareLink; Martin, 5 November 2026).
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { requestDbTrace } from "@/lib/data";
import { bareHrefsOf, breadcrumbs, visibleNav, type Crumb, type NavHref, type ShellPage } from "@/lib/nav";
import { NavBareLink } from "./NavGroup";
import { frameReads } from "./ShellFrame";

export type { ShellPage };

export async function Shell({
  copy,
  me,
  active,
  activeHref,
  wide = false,
  trail = [],
  children,
}: {
  copy: Copy;
  me: Principal;
  active: ShellPage;
  /**
   * The page's own address when several rail pages share its ShellPage: a contact center's Live board (addition 0008zv),
   * so its breadcrumb carries its organisation's name
   */
  activeHref?: NavHref;
  /**
   * Report and operational screens with wide tables: the width up to 1536 px (max-w-screen-2xl), as Pulse4all-Style
   * 7.1 allows operational screens (Decision log, 19 October 2026); the other pages keep the narrow column
   */
  wide?: boolean;
  /** Crumbs a page appends after the derived ones (the connection's name on Sources) */
  trail?: Crumb[];
  children: ReactNode;
}) {
  const crumbs = breadcrumbs(me, copy, active, trail, activeHref);
  // Verification only (CMA_DB_TRACE=1 with mock sign-in): the request's database count after every read of the page and
  // of the frame has completed, for verify/round-trips.mjs; never rendered in iap mode. The frame's reads are the same
  // request's (React cache), awaited here only while tracing, so a page in prod never waits for the frame
  if (requestDbTrace() !== null && me.canPreview) await frameReads();
  const dbTrace = requestDbTrace({ firstPaint: true });
  const bare = crumbs.length > 0 ? bareHrefsOf(visibleNav(me, copy)) : [];

  return (
    <>
      {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      {crumbs.length > 0 ? <Breadcrumbs crumbs={crumbs} label={copy.shell.breadcrumb} bare={bare} /> : null}
      <div className={wide ? "max-w-screen-2xl" : "max-w-4xl"}>{children}</div>
    </>
  );
}

function Breadcrumbs({ crumbs, label, bare }: { crumbs: Crumb[]; label: string; bare: readonly string[] }) {
  return (
    <nav aria-label={label} data-testid="breadcrumbs" className="mb-4">
      <ol className="flex flex-wrap items-center gap-1 text-caption text-p4a-grey">
        {crumbs.map((c, i) => {
          const last = i === crumbs.length - 1;
          return (
            <li key={`${i}-${c.label}`} className="flex items-center gap-1">
              {i > 0 ? (
                <svg aria-hidden="true" viewBox="0 0 16 16" className="h-4 w-4 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M6 4l4 4-4 4" />
                </svg>
              ) : null}
              {last ? (
                <span aria-current="page" className="font-semibold text-p4a-inkt">{c.label}</span>
              ) : c.href && bare.includes(c.href) ? (
                <NavBareLink href={c.href} prefetch={false} className="hover:text-p4a-deepblue hover:underline">{c.label}</NavBareLink>
              ) : c.href ? (
                <Link href={c.href} prefetch={false} className="hover:text-p4a-deepblue hover:underline">{c.label}</Link>
              ) : (
                <span>{c.label}</span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
