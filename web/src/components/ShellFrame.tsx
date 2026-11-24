/**
 * App frame: top bar, left rail, content. White top bar, the rail on Background Blue, the content
 * area Sand with white cards (Pulse4all-Style.md 2 and 7.3, decided 7 October 2026). Welcome is
 * a page of its own at the top of the rail; the other pages sit in groups (Live, Team, Time, Reports, Sales,
 * Customers, Campaigns, Configuration; the model lives in lib/nav). Shortcut keys are shown as keycaps and wired through data-shortcut
 * (see hooks/useKeyboardShortcuts), and named for assistive tech in aria-keyshortcuts.
 *
 * Since 16 October 2026 the rail folds to icons (cookie cma-rail, the toggle at its foot, W), the
 * content area carries breadcrumbs (lib/nav breadcrumbs(), drawn by the page's Shell), the keyboard hints can be hidden
 * (cookie cma-hints, ?) and an admin can preview the Workspace as a role (the select in the top bar, the
 * banner above the breadcrumbs; lib/auth/preview). The fold and the hints are data attributes on the
 * frame that globals.css styles, read from the cookies here on the server, so a page renders in its
 * state without a flicker and a click changes it at once (ShellPrefs).
 *
 * The persistent frame (night N07, decision D2, 24 November 2026): the route group app/(shell) renders this frame once in
 * its layout for every page that has it; a page renders only its content (Shell: the breadcrumbs, the content's width and
 * the page). A click between two pages of the group re-renders the page alone: the top bar, the rail with its open group
 * and its fold, the hints and the message centre with its poll and its badge stay as they are, and the destination's
 * loading boundary draws its content skeleton inside main. The rail item marked current follows the address on the
 * client (NavCurrent, lib/nav currentHrefOf), since the frame is not rendered again on a navigation. Invitation, Log out,
 * No access and the roster's print view stay outside the group; Log out draws this frame itself with Welcome current.
 *
 * Prefetch (decision D5): the rail's links prefetch their destination's loading boundary (Next's default for a dynamic
 * route, since night N06), and a link to a route of 131's agent class prefetches the whole page with its data once a
 * pointer or the focus rests on it for 100 ms (RailLink). Log out never prefetches: a prefetch of it would reach the
 * logout page. The Follow-up report no longer refreshes the page every 10 seconds (it polls an API route, N07), so the
 * rail's links prefetch on that page as on every other.
 *
 * Since 23 October 2026 the frame is exactly the viewport: main and the rail are the only scroll containers.
 */
import Image from "next/image";
import Link from "next/link";
import { cookies } from "next/headers";
import { cache, type ReactNode } from "react";
import { getAccess, rolesOf, type Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { config } from "@/lib/config";
import { HINTS_COOKIE, NAV_OPEN_COOKIE, openGroupOf, RAIL_COOKIE, visibleNav } from "@/lib/nav";
import { Keycap, Notice } from "./primitives";
import { AccountLink, NavAccordion, NavCurrent, NavGroup, NavIconMark, RailLink } from "./NavGroup";
import { Shortcuts } from "./Shortcuts";
import { MessageCenter } from "./MessageCenter";
import { HintsToggle, RailToggle } from "./ShellPrefs";
import { ExitPreview, PreviewSelect } from "./PreviewControls";

/**
 * The frame's own reads, once per request (React cache): the tenant's roles for an admin's preview select. The page's
 * Shell awaits them too while the database trace is on (verification only), so the trace it writes counts the frame's
 * reads as the single Shell's did before the frame persisted
 */
export const frameReads = cache(async (): Promise<{ roles: { key: string; name: string }[] }> => {
  const access = await getAccess();
  if (access?.kind !== "granted" || !access.principal.canPreview) return { roles: [] };
  const roles = await rolesOf(access.real).catch(() => []);
  return { roles: roles.map((r) => ({ key: r.key, name: r.name })) };
});

export async function ShellFrame({
  copy,
  me,
  currentHref,
  children,
}: {
  copy: Copy;
  me: Principal;
  /** The rail item to mark current on a page outside the group (Log out: "/"); inside the group the address decides */
  currentHref?: string | null;
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
  const t = copy.shell;
  // Preview as role: the tenant's roles for the select, listed with the real principal (the mock checks
  // the caller's own permissions, which a preview narrows; the database checks the real user either way)
  const { roles } = me.canPreview ? await frameReads() : { roles: [] };
  const ownRoleName = roles.find((r) => r.key === me.roleKey)?.name ?? me.roleKey;
  const hrefs = nav.flatMap((e) => (e.kind === "page" ? [e.item.href] : e.items.map((i) => i.href)));

  return (
    <div
      data-rail={collapsed ? "collapsed" : "expanded"}
      data-hints={hintsHidden ? "hidden" : "shown"}
      className="cma-frame grid h-full grid-cols-[var(--rail-width)_1fr] grid-rows-[var(--spacing-topbar)_minmax(0,1fr)] overflow-hidden"
    >
      <Shortcuts />
      {/* The rail's open group, for the rail and the top bar's inbox (a bare rail page closes it, addition 0008zv); a
          context only, so the frame's grid keeps the header, the rail and main as its own children. NavCurrent: the
          current rail item from the address (D2) */}
      <NavAccordion initial={openGroup}>
      <NavCurrent hrefs={hrefs} fixed={currentHref}>
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
          {/* The inbox with its unread count, the toasts and the urgent pop-up (migration 0008): mounted once per tab, so
              its poll and its badge live on across navigations (D2) */}
          <MessageCenter copy={copy.messages} />
          {me.canPreview ? (
            <PreviewSelect roles={roles.filter((r) => r.key !== me.roleKey)} current={me.preview?.roleKey ?? null} ownRoleName={ownRoleName} copy={t} />
          ) : null}
          <span className="text-p4a-muted">
            {t.signedInAs}{" "}
            <AccountLink
              title={t.openAccount}
              className="font-semibold text-p4a-body underline-offset-2 hover:text-p4a-deepblue hover:underline"
            >
              {me.displayName}
            </AccountLink>
            <span className="text-p4a-muted"> · {me.organisationName}</span>
          </span>
          {/* Log out keeps the width it has with its keycap when the hints hide (19 October 2026), so nothing in the
              top bar moves: the label with the keycap and the label alone share one grid cell, the wider one sets
              the width and the one shown is centred in it (globals.css, data-logout). It never prefetches (D5) */}
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

      <nav aria-label={copy.app.name} data-rail-nav className="flex min-h-0 flex-col overflow-y-auto border-r border-p4a-border bg-p4a-bgblue px-4 py-6">
        <ul className="flex flex-col gap-2">
          {nav.map((entry) => {
            if (entry.kind === "page") {
              // The label with its key is the name in the folded rail (title and aria-label); the keycap is hidden there
              const name = entry.item.key ? `${entry.item.label} (${entry.item.key})` : entry.item.label;
              // A bare page closes the open group on its click or digit key (addition 0008zv)
              return (
                <li key={entry.item.href}>
                  <RailLink
                    href={entry.item.href}
                    bare
                    data-shortcut={entry.item.key ?? undefined}
                    aria-keyshortcuts={entry.item.key ?? undefined}
                    title={name}
                    aria-label={name}
                    className="flex h-10 items-center gap-3 rounded-button px-3 text-body font-semibold"
                    currentClassName="bg-white text-p4a-deepblue"
                    idleClassName="text-p4a-heading hover:bg-white/60"
                  >
                    <NavIconMark name={entry.icon} />
                    <span data-rail-text className="min-w-0 flex-1 truncate">{entry.item.label}</span>
                    {entry.item.key ? <Keycap data-rail-text>{entry.item.key}</Keycap> : null}
                  </RailLink>
                </li>
              );
            }
            return (
              <NavGroup
                key={entry.id}
                id={entry.id}
                label={entry.label}
                icon={entry.icon}
                hrefs={entry.items.map((i) => i.href)}
                shortcut={entry.shortcut}
              >
                {entry.items.map((item) => (
                  // keyed by href: a contact center's Live boards share one ShellPage (addition 0008zv)
                  <li key={item.href}>
                    <RailLink
                      href={item.href}
                      data-shortcut={item.key ?? undefined}
                      aria-keyshortcuts={item.key ?? undefined}
                      className="flex h-10 items-center justify-between rounded-button px-3 text-body"
                      currentClassName="bg-white font-semibold text-p4a-deepblue"
                      idleClassName="text-p4a-body hover:bg-white/60"
                    >
                      {item.label}
                      {item.key ? <Keycap>{item.key}</Keycap> : null}
                    </RailLink>
                  </li>
                ))}
              </NavGroup>
            );
          })}
        </ul>
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

      <main className="relative min-h-0 overflow-y-auto bg-p4a-sand px-10 py-8">
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
        {children}
      </main>
      </NavCurrent>
      </NavAccordion>
    </div>
  );
}
