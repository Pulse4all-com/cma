import Link from "next/link";
import type { Route } from "next";
import { DashedSection, PlaceholderBanner } from "@/components/CampaignParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { StatusBadge } from "@/components/StatusBadge";
import { Badge, PageTitle } from "@/components/primitives";
import { activeCopy, type Copy } from "@/lib/copy";
import type { Principal } from "@/lib/auth/identity";
import { flashHref } from "@/lib/flash";
import { holdsAny, navEntries, type NavItem } from "@/lib/nav";

/**
 * A placeholder page of the rail (Martin, 13 November 2026): the Decision log's rule for placeholders (11 November 2026,
 * D5: "Placeholders reserve the slot") extended from a card to a whole page. It shows the page's purpose in one sentence,
 * the Muted banner, a Neutral "Not connected yet" badge (Active's own words), its definition status (Pending) and, in a
 * dashed section, what will feed it, with a link to Flash where Flash already holds today's figures. Never a number, a
 * zero or a dash that reads as one, and never customer data; no read beyond what Shell already does. The parts are
 * Campaign monitoring's (CampaignParts: the banner, the dashed section) and Active's (StatusBadge, the definition's status).
 * The permission is the rail item's own (lib/nav), so the page and the rail can never disagree.
 */
export type PlaceholderKey = "subscriptions" | "payments" | "compliance" | "qualityMonitoring" | "purchaseOrders";

const PAGES: Record<PlaceholderKey, { page: NavItem["page"]; flash?: "subscriptions" | "payments" }> = {
  subscriptions: { page: "subscriptions", flash: "subscriptions" },
  payments: { page: "payments", flash: "payments" },
  compliance: { page: "compliance" },
  qualityMonitoring: { page: "quality-monitoring" },
  purchaseOrders: { page: "purchase-orders" },
};

/** The rail's item of a page: its label and its permission */
function itemOf(copy: Copy, page: NavItem["page"]): NavItem {
  const item = navEntries(copy, []).flatMap((e) => (e.kind === "page" ? [e.item] : e.items)).find((i) => i.page === page);
  if (!item) throw new Error(`no rail item for ${page}`);
  return item;
}

export function PlaceholderPage({ which, me, copy }: { which: PlaceholderKey; me: Principal; copy: Copy }) {
  const t = copy.placeholders;
  const def = PAGES[which];
  const item = itemOf(copy, def.page);

  if (!holdsAny(me, item.permission)) {
    return (
      <Shell copy={copy} me={me} active={def.page}>
        <PageTitle>{item.label}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  return (
    <Shell copy={copy} me={me} active={def.page}>
      <PageTitle>{item.label}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted" data-testid="placeholder-intro">{t[`intro_${which}`]}</p>
      <PlaceholderBanner testId="placeholder-banner">{t.banner}</PlaceholderBanner>

      <div className="mb-6 flex flex-wrap items-center gap-4" data-testid="placeholder-status">
        <Badge tone="neutral">{activeCopy[me.locale].notConnected}</Badge>
        <span className="inline-flex items-center gap-2 text-small text-p4a-muted">
          {t.definitionTitle}
          <StatusBadge status="Pending" copy={copy} />
        </span>
      </div>

      <div className="grid max-w-3xl grid-cols-1 gap-6">
        <DashedSection title={t.fedByTitle} testId="placeholder-fed-by">
          <p>{t[`fedBy_${which}`]}</p>
          {def.flash ? (
            <p className="mt-3">
              <Link href={flashHref("/reports/flash", { o: def.flash }) as Route} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline"
                data-testid="placeholder-flash">
                {t[`link_${def.flash}`]}
              </Link>
            </p>
          ) : null}
        </DashedSection>
      </div>
    </Shell>
  );
}
