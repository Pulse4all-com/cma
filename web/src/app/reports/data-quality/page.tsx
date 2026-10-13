import Link from "next/link";
import { HeaderHint } from "@/components/HeaderHint";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import { data, dataIsMock, type DataQualityCheck } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { DATA_QUALITY_PERMISSIONS, fmtCount, isMuted, orderChecks } from "@/lib/reports";
import { resolve } from "../../access";

/** The check's name and what fixing it means, from copy; a check this screen does not know keeps the database's description */
function describe(c: DataQualityCheck, copy: Copy): { label: string; fix: string } {
  const t = copy.dataQuality as Record<string, string>;
  return { label: t[`check_${c.key}`] ?? c.description, fix: t[`fix_${c.key}`] ?? "" };
}

/**
 * Data quality (Report, B11): one row per check of cma.data_quality() (migration 0007d) with its
 * current count and one line on what fixing it means, and the outbox guard's row (outbox_pending,
 * brief A5) while its count is above 0; checks with nothing to fix are muted, and CRM
 * owners without a person come first. Shown to people holding reports.view or tenant.configure; the
 * database checks again on every read. Counts only, no record of any customer. Every column header
 * explains itself in a hint (copy.hints).
 */
export default async function DataQualityPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.dataQuality;

  if (!holdsAny(me, DATA_QUALITY_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="data-quality">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const checks = orderChecks(await data().getDataQuality(me));
  // The checks a person fixes by linking ids on People (addition 0008e), shown as a link to whoever may open People
  const linksToPeople = new Set(["owner_without_person", "telephony_user_without_person"]);
  const mayOpenPeople = holdsAny(me, ["users.manage_agents", "users.manage_all"]);
  const h = copy.hints;
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={text} />;
  const th = "h-10 whitespace-nowrap px-3 font-semibold";
  const td = "px-3 py-3 align-top";

  return (
    <Shell copy={copy} me={me} active="data-quality" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <Card>
        <table className="w-full border-collapse text-body" data-testid="data-quality">
          <thead>
            <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
              <th className={`${th} w-80`}>{t.check}{hint(t.check, h.check)}</th>
              <th className={`${th} w-28 text-right`}>{t.count}{hint(t.count, h.count)}</th>
              <th className={th}>{t.fix}{hint(t.fix, h.fix)}</th>
            </tr>
          </thead>
          <tbody>
            {checks.map((c) => {
              const { label, fix } = describe(c, copy);
              const muted = isMuted(c);
              return (
                <tr key={c.key} data-check={c.key} data-muted={muted ? "true" : "false"}
                  className={`border-b border-p4a-border last:border-b-0 ${muted ? "text-p4a-muted" : ""}`}>
                  <td className={`${td} ${muted ? "" : "font-semibold text-p4a-heading"}`}>{label}</td>
                  <td className={`${td} tabular text-right ${muted ? "" : "font-semibold text-p4a-heading"}`}>
                    {c.total === null ? <span className="text-small">{t.notAvailable}</span> : fmtCount(c.total, me.locale)}
                  </td>
                  <td className={`${td} text-small`}>
                    {fix}
                    {linksToPeople.has(c.key) && mayOpenPeople ? (
                      <Link href="/team/people" className="ml-2 font-semibold text-p4a-deepblue underline" data-testid={`dq-link-${c.key}`}>{t.linkPeople}</Link>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
