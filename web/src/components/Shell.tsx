/**
 * App frame: top bar, left rail, content. Operational white page (7.1), the
 * rail on Background Blue. Shortcut keys are shown as keycaps and wired through
 * data-shortcut (see hooks/useKeyboardShortcuts).
 */
import Image from "next/image";
import Link from "next/link";
import type { ReactNode } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { config } from "@/lib/config";
import { Keycap } from "./primitives";
import { Shortcuts } from "./Shortcuts";

export type ShellPage = "my-day" | "my-hours" | "team-hours";

type NavItem = { page: ShellPage; href: "/" | "/hours" | "/team/hours"; label: string; permission?: string };

export function Shell({
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
  // Keys follow the visible order, so every person's pages are numbered 1, 2, 3 without gaps.
  const items: NavItem[] = [
    { page: "my-day", href: "/", label: copy.nav.myDay },
    { page: "my-hours", href: "/hours", label: copy.nav.myHours },
    { page: "team-hours", href: "/team/hours", label: copy.nav.teamHours, permission: "workday.team" },
  ];
  const nav = items
    .filter((i) => !i.permission || me.permissions.includes(i.permission))
    .map((i, n) => ({ ...i, key: String(n + 1) }));

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
        <ul className="flex flex-col gap-1">
          {nav.map((item) => {
            const current = item.page === active;
            return (
              <li key={item.page}>
                <Link
                  href={item.href}
                  aria-current={current ? "page" : undefined}
                  data-shortcut={item.key}
                  className={[
                    "flex h-10 items-center justify-between rounded-button px-3 text-body",
                    current
                      ? "bg-white font-semibold text-p4a-deepblue"
                      : "text-p4a-body hover:bg-white/60",
                  ].join(" ")}
                >
                  {item.label}
                  <Keycap>{item.key}</Keycap>
                </Link>
              </li>
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

      <main className="overflow-y-auto bg-white px-10 py-8">
        <div className={wide ? "max-w-6xl" : "max-w-4xl"}>{children}</div>
      </main>
    </div>
  );
}
