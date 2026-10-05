/**
 * App frame: top bar, left rail, content. Operational white page (7.1), the
 * rail on Background Blue. Shortcut keys are shown as keycaps; the key handler
 * itself arrives with the screens in the next increment.
 */
import Image from "next/image";
import Link from "next/link";
import type { ReactNode } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { config } from "@/lib/config";
import { Keycap } from "./primitives";

export type ShellPage = "my-day" | "my-hours";

export function Shell({
  copy,
  me,
  active,
  children,
}: {
  copy: Copy;
  me: Principal;
  active: ShellPage;
  children: ReactNode;
}) {
  const nav: { page: ShellPage; href: "/" | "/hours"; label: string; key: string }[] = [
    { page: "my-day", href: "/", label: copy.nav.myDay, key: "1" },
    { page: "my-hours", href: "/hours", label: copy.nav.myHours, key: "2" },
  ];

  return (
    <div className="grid h-full grid-cols-[var(--spacing-rail)_1fr] grid-rows-[var(--spacing-topbar)_1fr]">
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
        <div className="max-w-4xl">{children}</div>
      </main>
    </div>
  );
}
