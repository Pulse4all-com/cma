import type { ReactNode } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import type { ShellPage } from "@/lib/nav";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { dataIsMock } from "@/lib/data";

/**
 * The frame of every configuration page (migration 0005a): shown to people holding
 * tenant.configure (the admin in the default ladder); the database checks again on every read and
 * write. Everyone else gets the same calm page instead of a redirect, as People does.
 */
export function ConfigurationPage({ me, copy, active, title, intro, children }: {
  me: Principal; copy: Copy; active: ShellPage; title: string; intro: string; children: ReactNode;
}) {
  const c = copy.configuration;
  if (!me.permissions.includes("tenant.configure")) {
    return (
      <Shell copy={copy} me={me} active={active}>
        <PageTitle>{title}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{c.noPermissionTitle}</h2>
          <p className="mt-2 text-body">{c.noPermissionBody}</p>
        </Card>
      </Shell>
    );
  }
  return (
    <Shell copy={copy} me={me} active={active} wide>
      <PageTitle>{title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{intro}</p>
      <Card>{children}</Card>
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}

export const mayConfigure = (me: Principal) => me.permissions.includes("tenant.configure");
