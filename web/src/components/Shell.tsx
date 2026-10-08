/**
 * App frame: top bar, left rail, content. White top bar, the rail on Background Blue, the content
 * area Sand with white cards (Pulse4all-Style.md 2 and 7.3, decided 7 October 2026). Welcome is
 * a page of its own at the top of the rail; the other pages sit in groups (Live, Time, Reports; the
 * model lives in lib/nav). Shortcut keys are shown as keycaps and wired through data-shortcut
 * (see hooks/useKeyboardShortcuts).
 */
import Image from "next/image";
import Link from "next/link";
import { cookies } from "next/headers";
import type { ReactNode } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { config } from "@/lib/config";
import { Keycap } from "./primitives";
import { NAV_COOKIE_PREFIX, visibleNav, type ShellPage } from "@/lib/nav";
import { NavGroup, NavIconMark } from "./NavGroup";
import { Shortcuts } from "./Shortcuts";

export type { ShellPage };

export async function Shell({
  copy,
  me,
  active,
  wide = false,
  children,
}: {
  copy: Copy;
  me: Principal;
  active: ShellPage;
  /** Report screens with wide tables; operational screens keep the narrow column */
  wide?: boolean;
  children: ReactNode;
}) {
  // Screens check a permission, never a role key; the database checks again on every call.
  // Keys follow the visible order across all groups (lib/nav).
  const nav = visibleNav(me, copy);
  // Groups start closed; each browser remembers per group whether it was left open (a cookie,
  // so the page renders in that state without a flicker)
  const jar = await cookies();

  return (
    <div className="grid h-full grid-cols-[var(--spacing-rail)_1fr] grid-rows-[var(--spacing-topbar)_1fr]">
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
        <div className="flex items-center gap-6 text-small">
          <span className="text-p4a-muted">
            {copy.shell.signedInAs}{" "}
            <span className="font-semibold text-p4a-body">{me.displayName}</span>
            <span className="text-p4a-muted"> · {me.organisationName}</span>
          </span>
          <Link
            href="/logout"
            data-shortcut="l"
            className="inline-flex h-8 items-center gap-2 rounded-button border border-p4a-deepblue px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue"
          >
            {copy.nav.logOut}
            <Keycap>L</Keycap>
          </Link>
        </div>
      </header>

      <nav aria-label={copy.app.name} className="flex flex-col border-r border-p4a-border bg-p4a-bgblue px-4 py-6">
        <ul className="flex flex-col gap-2">
          {nav.map((entry) => {
            if (entry.kind === "page") {
              const current = entry.item.page === active;
              return (
                <li key={entry.item.page}>
                  <Link
                    href={entry.item.href}
                    aria-current={current ? "page" : undefined}
                    data-shortcut={entry.item.key}
                    className={[
                      "flex h-10 items-center gap-3 rounded-button px-3 text-body font-semibold",
                      current ? "bg-white text-p4a-deepblue" : "text-p4a-heading hover:bg-white/60",
                    ].join(" ")}
                  >
                    <NavIconMark name={entry.icon} />
                    <span className="min-w-0 flex-1 truncate">{entry.item.label}</span>
                    <Keycap>{entry.item.key}</Keycap>
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
                defaultOpen={jar.get(`${NAV_COOKIE_PREFIX}${entry.id}`)?.value === "open"}
                current={entry.items.some((i) => i.page === active)}
                shortcut={entry.shortcut}
              >
                {entry.items.map((item) => {
                  const current = item.page === active;
                  return (
                    <li key={item.page}>
                      <Link
                        href={item.href}
                        aria-current={current ? "page" : undefined}
                        data-shortcut={item.key ?? undefined}
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
        <div className="mt-auto flex flex-col gap-2 text-caption text-p4a-grey">
          <p>{copy.shell.shortcutsHint}</p>
          <p className="tabular">
            {copy.shell.version} {config.version}
          </p>
        </div>
      </nav>

      <main className="overflow-y-auto bg-p4a-sand px-10 py-8">
        <div className={wide ? "max-w-6xl" : "max-w-4xl"}>{children}</div>
      </main>
    </div>
  );
}
