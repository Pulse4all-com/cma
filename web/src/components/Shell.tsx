/**
 * App frame: top bar, left rail, content. White top bar, the rail on Background Blue, the content
 * area Sand with white cards (Pulse4all-Style.md 2 and 7.3, decided 7 October 2026). Welcome is
 * a page of its own at the top of the rail; the other pages sit in groups (Live, Time, Reports; the
 * model lives in lib/nav). Shortcut keys are shown as keycaps and wired through data-shortcut
 * (see hooks/useKeyboardShortcuts), and named for assistive tech in aria-keyshortcuts.
 *
 * Since 16 October 2026 the rail folds to icons (cookie cma-rail, the toggle at its foot, W), the
 * content area carries breadcrumbs (lib/nav breadcrumbs()), the keyboard hints can be hidden (cookie
 * cma-hints, ?) and an admin can preview the Workspace as a role (the select in the top bar, the
 * banner above the breadcrumbs; lib/auth/preview). The fold and the hints are data attributes on the
 * frame that globals.css styles, read from the cookies here on the server, so a page renders in its
 * state without a flicker and a click changes it at once (ShellPrefs).
 *
 * The frame's links never prefetch (prefetch={false}, Decision log 18 October 2026): every page is dynamic and has
 * no loading boundary, so a prefetch carried no page data, and the router.refresh() of a polled page (LiveRefresh)
 * invalidated the client cache, so each poll fetched every visible link's route again. A click loads the page as
 * before, in one request.
 */
import Image from "next/image";
import Link from "next/link";
import { cookies } from "next/headers";
import type { ReactNode } from "react";
import { getAccess, rolesOf, type Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { config } from "@/lib/config";
import { requestDbTrace } from "@/lib/data";
import { Keycap, Notice } from "./primitives";
import { breadcrumbs, HINTS_COOKIE, NAV_OPEN_COOKIE, openGroupOf, RAIL_COOKIE, visibleNav, type Crumb, type ShellPage } from "@/lib/nav";
import { NavAccordion, NavGroup, NavIconMark } from "./NavGroup";
import { Shortcuts } from "./Shortcuts";
import { MessageCenter } from "./MessageCenter";
import { HintsToggle, RailToggle } from "./ShellPrefs";
import { ExitPreview, PreviewSelect } from "./PreviewControls";

export type { ShellPage };

export async function Shell({
  copy,
  me,
  active,
  wide = false,
  trail = [],
  children,
}: {
  copy: Copy;
  me: Principal;
  active: ShellPage;
  /**
   * Report and operational screens with wide tables: the width up to 1536 px (max-w-screen-2xl), as Pulse4all-Style
   * 7.1 allows operational screens (Decision log, 19 October 2026); the other pages keep the narrow column
   */
  wide?: boolean;
  /** Crumbs a page appends after the derived ones (the connection's name on Sources) */
  trail?: Crumb[];
  children: ReactNode;
}) {
  // Screens check a permission, never a role key; the database checks again on every call.
  // Keys follow the visible order across all groups (lib/nav).
  const nav = visibleNav(me, copy);
  // At most one group is open (19 October 2026): the browser remembers which in one cookie, so the page renders
  // with it open and never flickers (the retired per-group cookies are ignored); the rail's fold and the hints alike
  const jar = await cookies();
  const openGroup = openGroupOf(jar.get(NAV_OPEN_COOKIE)?.value, nav.flatMap((e) => (e.kind === "group" ? [e.id] : [])));
  const collapsed = jar.get(RAIL_COOKIE)?.value === "collapsed";
  const hintsHidden = jar.get(HINTS_COOKIE)?.value === "hidden";
  const crumbs = breadcrumbs(me, copy, active, trail);
  const t = copy.shell;
  // Preview as role: the tenant's roles for the select, listed with the real principal (the mock checks
  // the caller's own permissions, which a preview narrows; the database checks the real user either way)
  const access = me.canPreview ? await getAccess() : null;
  const roles = access?.kind === "granted" ? await rolesOf(access.real).catch(() => []) : [];
  const ownRoleName = roles.find((r) => r.key === me.roleKey)?.name ?? me.roleKey;
  // Verification only (CMA_DB_TRACE=1 with mock sign-in): the request's database count after every read of the
  // page and the Shell has completed, for verify/round-trips.mjs; never rendered in iap mode
  const dbTrace = requestDbTrace();

  return (
    <div
      data-rail={collapsed ? "collapsed" : "expanded"}
      data-hints={hintsHidden ? "hidden" : "shown"}
      className="cma-frame grid h-full grid-cols-[var(--rail-width)_1fr] grid-rows-[var(--spacing-topbar)_1fr]"
    >
      {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      <Shortcuts />
      <header className="col-span-2 flex items-center justify-between border-b border-p4a-border bg-white px-6">
        <div className="flex items-center gap-4">
          <Image
            src="/brand/logo-blue.png"
            alt="Pulse4all"
            width={141}
            height={28}
            priority
            className="h-7 w-auto"
          />
          <span className="border-l border-p4a-border pl-4 text-small text-p4a-muted">
            {copy.app.name}
          </span>
        </div>
        <div className="flex items-center gap-5 text-small">
          {/* Show or hide the keyboard hints (backlog CMA-004), left of the inbox */}
          <HintsToggle hidden={hintsHidden} copy={t} />
          {/* The inbox with its unread count, the toasts and the urgent pop-up (migration 0008) */}
          <MessageCenter copy={copy.messages} active={active === "messages" || active === "messages-send"} />
          {me.canPreview ? (
            <PreviewSelect roles={roles.filter((r) => r.key !== me.roleKey).map((r) => ({ key: r.key, name: r.name }))} current={me.preview?.roleKey ?? null} ownRoleName={ownRoleName} copy={t} />
          ) : null}
          <span className="text-p4a-muted">
            {t.signedInAs}{" "}
            <Link
              href="/account"
              prefetch={false}
              title={t.openAccount}
              aria-current={active === "account" ? "page" : undefined}
              className="font-semibold text-p4a-body underline-offset-2 hover:text-p4a-deepblue hover:underline"
            >
              {me.displayName}
            </Link>
            <span className="text-p4a-muted"> · {me.organisationName}</span>
          </span>
          {/* Log out keeps the width it has with its keycap when the hints hide (19 October 2026), so nothing in the
              top bar moves: the label with the keycap and the label alone share one grid cell, the wider one sets
              the width and the one shown is centred in it (globals.css, data-logout) */}
          <Link
            href="/logout"
            prefetch={false}
            data-shortcut="l"
            aria-keyshortcuts="L"
            aria-label={copy.nav.logOut}
            data-testid="logout"
            className="inline-grid h-8 place-items-center rounded-button border border-p4a-deepblue px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue"
          >
            <span data-logout="with-key" className="col-start-1 row-start-1 inline-flex items-center gap-2">
              {copy.nav.logOut}
              <Keycap>L</Keycap>
            </span>
            <span data-logout="bare" aria-hidden="true" className="invisible col-start-1 row-start-1">{copy.nav.logOut}</span>
          </Link>
        </div>
      </header>

      <nav aria-label={copy.app.name} data-rail-nav className="flex flex-col border-r border-p4a-border bg-p4a-bgblue px-4 py-6">
        <NavAccordion initial={openGroup}>
        <ul className="flex flex-col gap-2">
          {nav.map((entry) => {
            if (entry.kind === "page") {
              const current = entry.item.page === active;
              // The label with its key is the name in the folded rail (title and aria-label); the keycap is hidden there
              const name = entry.item.key ? `${entry.item.label} (${entry.item.key})` : entry.item.label;
              return (
                <li key={entry.item.page}>
                  <Link
                    href={entry.item.href}
                    prefetch={false}
                    aria-current={current ? "page" : undefined}
                    data-shortcut={entry.item.key ?? undefined}
                    aria-keyshortcuts={entry.item.key ?? undefined}
                    title={name}
                    aria-label={name}
                    className={[
                      "flex h-10 items-center gap-3 rounded-button px-3 text-body font-semibold",
                      current ? "bg-white text-p4a-deepblue" : "text-p4a-heading hover:bg-white/60",
                    ].join(" ")}
                  >
                    <NavIconMark name={entry.icon} />
                    <span data-rail-text className="min-w-0 flex-1 truncate">{entry.item.label}</span>
                    {entry.item.key ? <Keycap data-rail-text>{entry.item.key}</Keycap> : null}
                  </Link>
                </li>
              );
            }
            return (
              <NavGroup
                key={entry.id}
                id={entry.id}
                label={entry.label}
                icon={entry.icon}
                current={entry.items.some((i) => i.page === active)}
                shortcut={entry.shortcut}
              >
                {entry.items.map((item) => {
                  const current = item.page === active;
                  return (
                    <li key={item.page}>
                      <Link
                        href={item.href}
                        prefetch={false}
                        aria-current={current ? "page" : undefined}
                        data-shortcut={item.key ?? undefined}
                        aria-keyshortcuts={item.key ?? undefined}
                        className={[
                          "flex h-10 items-center justify-between rounded-button px-3 text-body",
                          current
                            ? "bg-white font-semibold text-p4a-deepblue"
                            : "text-p4a-body hover:bg-white/60",
                        ].join(" ")}
                      >
                        {item.label}
                        {item.key ? <Keycap>{item.key}</Keycap> : null}
                      </Link>
                    </li>
                  );
                })}
              </NavGroup>
            );
          })}
        </ul>
        </NavAccordion>
        <div className="mt-auto flex flex-col gap-2 text-caption text-p4a-grey">
          {/* The shortcuts line and the version hide with the fold; the shortcuts line also with the hints */}
          <div data-rail-text className="flex flex-col gap-2">
            <p data-shortcuts-hint>{t.shortcutsHint}</p>
            <p className="tabular">
              {t.version} {config.version}
            </p>
          </div>
          <RailToggle collapsed={collapsed} copy={t} />
        </div>
      </nav>

      <main className="overflow-y-auto bg-p4a-sand px-10 py-8">
        {me.preview ? (
          // Previewing: the person sees what the role sees; their own data and permissions are unchanged
          <div className="mb-6" data-testid="preview-banner">
            <Notice tone="info">
              <div className="flex items-center justify-between gap-4">
                <span>{t.previewBanner.replace("{role}", me.preview.roleName)}</span>
                <ExitPreview copy={t} />
              </div>
            </Notice>
          </div>
        ) : null}
        {crumbs.length > 0 ? <Breadcrumbs crumbs={crumbs} label={t.breadcrumb} /> : null}
        <div className={wide ? "max-w-screen-2xl" : "max-w-4xl"}>{children}</div>
      </main>
    </div>
  );
}

/**
 * Where the person is (16 October 2026): caption size in Footnote Grey, a 16 px chevron between the
 * crumbs, the last crumb Inkt semi-bold with aria-current and never a link. Welcome shows none.
 */
function Breadcrumbs({ crumbs, label }: { crumbs: Crumb[]; label: string }) {
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
