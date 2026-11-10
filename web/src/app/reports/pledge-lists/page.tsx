import Link from "next/link";
import type { ReactNode } from "react";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import type { PledgeFindingRows, PledgePage as PledgePageData } from "@/lib/data";
import { data, dataIsMock } from "@/lib/data";
import type { Copy, Locale } from "@/lib/copy";
import { holdsAny } from "@/lib/nav";
import { fmtAmount, isPledgeCheck, PLEDGE_CHECK_ROWS, PLEDGE_CHECKS, PLEDGE_PERMISSIONS, PLEDGES_PATH, type PledgeCheck } from "@/lib/pledges";
import { fmtCount } from "@/lib/reports";
import { fmtDate, fmtDateTime } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Assets → Pledge lists (addition 0009j; Martin, 10 November 2026, D1 to D8): the quarter files of the early-stage
 * investors' loans, each frozen on its quarter's first day and downloaded unchanged at any later time; today's version
 * per loan (devices, In Storage, the sums of the acquisition value, the current value and the receipts) with its own
 * download; and the checks before the next file, each count opening its devices' serial numbers (address state check=,
 * one at a time). Shown to people holding pledges.view, a permission no default role holds (D7); the database checks it
 * again on every read. Ids, serials, codes, dates and amounts, and the lender labels of the loan catalog; never a
 * customer's name, email, phone or address. Server-rendered links only: no client script of its own.
 */
export default async function PledgeListsPage({ searchParams }: PageProps<"/reports/pledge-lists">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.pledges;

  if (!holdsAny(me, PLEDGE_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="pledge-lists">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const raw = Array.isArray(sp.check) ? sp.check[0] : sp.check;
  const check: PledgeCheck | null = isPledgeCheck(raw) ? raw : null;
  const page = await data().getPledgePage(me, check, PLEDGE_CHECK_ROWS);
  const locale = me.locale;
  const h = copy.hints;

  return (
    <Shell copy={copy} me={me} active="pledge-lists" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      {!page.isSetUp ? (
        <div className="mb-6" data-testid="pledges-not-set-up"><Notice tone="info">{t.notSetUp}</Notice></div>
      ) : null}
      {page.isSetUp && page.quarter.due && !page.quarter.taken ? (
        <div className="mb-6" data-testid="pledges-quarter-missing">
          <Notice tone="warning">{t.quarterMissing.replace("{date}", fmtDate(page.quarter.start, locale, "long"))}</Notice>
        </div>
      ) : null}

      <div className="flex flex-col gap-6">
        <Card title={t.filesCard}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
            <HintLabel label={t.filesIntro}><HeaderHint label={h.about.replace("{label}", t.filesCard)} text={t.hintFiles} /></HintLabel>
          </p>
          <Files page={page} copy={copy} locale={locale} timeZone={me.timeZone} />
        </Card>

        <Card title={t.todayCard}>
          <div className="mb-4 flex flex-wrap items-center justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
              <HintLabel label={t.todayIntro.replace("{date}", fmtDate(page.today.valuationDate, locale, "long"))}>
                <HeaderHint label={h.about.replace("{label}", t.colCurrent)} text={t.hintToday} />
              </HintLabel>
            </p>
            {page.today.loans.length ? (
              <LinkButton href="/api/v1/reports/pledge-lists/files/today" download shortcut="X" data-shortcut="x" title={t.downloadTodayHint}
                data-testid="pledges-download-today">{t.downloadToday}</LinkButton>
            ) : null}
          </div>
          <Today page={page} copy={copy} locale={locale} />
        </Card>

        <Card title={t.checksCard}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
            <HintLabel label={t.checksIntro}><HeaderHint label={h.about.replace("{label}", t.checksCard)} text={t.hintChecks} /></HintLabel>
          </p>
          <Checks page={page} copy={copy} locale={locale} open={check} />
        </Card>

        {check && page.checkRows ? (
          <section id="devices" aria-label={t[`check_${check}`]}>
            <Card title={t.listCard.replace("{check}", t[`check_${check}`])}>
              <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
                <span className="text-p4a-muted" data-testid="pledges-check-count">
                  {t.listShown.replace("{shown}", fmtCount(page.checkRows.rows.length, locale)).replace("{total}", fmtCount(page.checkRows.total, locale))}
                </span>
                <Link href={PLEDGES_PATH} className="font-semibold text-p4a-deepblue underline">{t.close}</Link>
              </div>
              <Serials list={page.checkRows} copy={copy} />
            </Card>
          </section>
        ) : null}
      </div>

      {dataIsMock ? (
        <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div>
      ) : null}
    </Shell>
  );
}

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const thRight = `${th} text-right`;
const td = "h-10 whitespace-nowrap px-2";
const tdNum = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

function Table({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

function Files({ page, copy, locale, timeZone }: { page: PledgePageData; copy: Copy; locale: Locale; timeZone: string }) {
  const t = copy.pledges;
  if (page.files.length === 0) return <p className="text-body text-p4a-muted">{t.filesEmpty}</p>;
  return (
    <Table testId="pledges-files" label={t.filesCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}>{t.colValuationDate}</th>
          <th className={th}>{t.colTakenAt}</th>
          <th className={thRight}>{t.colLoans}</th>
          <th className={thRight}>{t.colDevices}</th>
          <th className={th}>{t.colDownload}</th>
        </tr>
      </thead>
      <tbody>
        {page.files.map((f) => (
          <tr key={f.valuationDate} className={row} data-file={f.valuationDate}>
            <td className={`${td} font-semibold tabular`}>{fmtDate(f.valuationDate, locale, "long")}</td>
            <td className={`${td} tabular`}>{fmtDateTime(f.takenAt, timeZone, locale)}</td>
            <td className={tdNum}>{fmtCount(f.loans, locale)}</td>
            <td className={tdNum}>{fmtCount(f.devices, locale)}</td>
            <td className={td}>
              <a href={`/api/v1/reports/pledge-lists/files/${f.valuationDate}`} download className="font-semibold text-p4a-deepblue underline">{t.downloadFile}</a>
            </td>
          </tr>
        ))}
      </tbody>
    </Table>
  );
}

/** Two decimal texts summed as cents, back to text (no float on a money figure) */
function addAmounts(a: string, b: string): string {
  const cents = (v: string) => BigInt(v.replace(".", "").replace(/^(-?)0+(?=\d)/, "$1"));
  const c = cents(a.includes(".") ? a : `${a}.00`) + cents(b.includes(".") ? b : `${b}.00`);
  const neg = c < BigInt(0);
  const abs = (neg ? -c : c).toString().padStart(3, "0");
  return `${neg ? "-" : ""}${abs.slice(0, -2)}.${abs.slice(-2)}`;
}

function Today({ page, copy, locale }: { page: PledgePageData; copy: Copy; locale: Locale }) {
  const t = copy.pledges;
  const loans = page.today.loans;
  if (loans.length === 0) return <p className="text-body text-p4a-muted">{t.todayEmpty}</p>;
  const n = (x: number) => fmtCount(x, locale);
  const total = loans.reduce((s, l) => ({ devices: s.devices + l.devices, inStorage: s.inStorage + l.inStorage,
    acq: addAmounts(s.acq, l.acquisitionValue), cur: addAmounts(s.cur, l.currentValue), rec: addAmounts(s.rec, l.receipts) }),
  { devices: 0, inStorage: 0, acq: "0.00", cur: "0.00", rec: "0.00" });
  return (
    <Table testId="pledges-today" label={t.todayCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={thRight}>{t.colLoan}</th>
          <th className={th}>{t.colLender}</th>
          <th className={thRight}>{t.colDevices}</th>
          <th className={thRight}>{t.colInStorage}</th>
          <th className={thRight}>{t.colAcquisition}</th>
          <th className={thRight}>{t.colCurrent}</th>
          <th className={thRight}>{t.colReceipts}</th>
        </tr>
      </thead>
      <tbody>
        {loans.map((l) => (
          <tr key={l.number} className={row} data-loan={l.number}>
            <td className={`${tdNum} font-semibold`}>{l.number}</td>
            <td className={td}>{l.lenderLabel}</td>
            <td className={tdNum}>{n(l.devices)}</td>
            <td className={tdNum}>{n(l.inStorage)}</td>
            <td className={tdNum}>{fmtAmount(l.acquisitionValue, locale)}</td>
            <td className={tdNum}>{fmtAmount(l.currentValue, locale)}</td>
            <td className={tdNum}>{fmtAmount(l.receipts, locale)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr className="font-semibold text-p4a-body" data-row="total">
          <td className={td} colSpan={2}>{t.totalRow}</td>
          <td className={tdNum}>{n(total.devices)}</td>
          <td className={tdNum}>{n(total.inStorage)}</td>
          <td className={tdNum}>{fmtAmount(total.acq, locale)}</td>
          <td className={tdNum}>{fmtAmount(total.cur, locale)}</td>
          <td className={tdNum}>{fmtAmount(total.rec, locale)}</td>
        </tr>
      </tfoot>
    </Table>
  );
}

function Checks({ page, copy, locale, open }: { page: PledgePageData; copy: Copy; locale: Locale; open: PledgeCheck | null }) {
  const t = copy.pledges;
  const any = PLEDGE_CHECKS.some((k) => (page.checks[k] ?? 0) > 0);
  if (!any) return <p className="text-body text-p4a-muted" data-testid="pledges-checks-none">{t.checksNone}</p>;
  return (
    <ul className="flex flex-col gap-2 text-body" data-testid="pledges-checks">
      {PLEDGE_CHECKS.map((k) => {
        const count = page.checks[k] ?? 0;
        return (
          <li key={k} className="flex flex-wrap items-baseline gap-3" data-check={k}>
            {count > 0 ? (
              <Link href={{ pathname: PLEDGES_PATH, query: { check: k }, hash: "devices" }} aria-current={open === k ? "true" : undefined}
                className="min-w-12 text-right font-semibold tabular text-p4a-deepblue underline">{fmtCount(count, locale)}</Link>
            ) : (
              <span className="min-w-12 text-right tabular text-p4a-muted">{fmtCount(0, locale)}</span>
            )}
            <span>{t[`check_${k}`]}</span>
            {k === "no_language" && page.unmappedLanguages.length ? (
              <span className="text-small text-p4a-muted">
                {t.unmappedLabels.replace("{labels}", page.unmappedLanguages.map((u) => `${u.label} (${fmtCount(u.devices, locale)})`).join(", "))}
              </span>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}

function Serials({ list, copy }: { list: PledgeFindingRows; copy: Copy }) {
  const t = copy.pledges;
  const withValue = list.check === "unknown_loan" || list.check === "no_model_values" || list.check === "no_language";
  return (
    <Table testId="pledges-serials" label={t.listCard.replace("{check}", list.check)}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}>{t.colSerial}</th>
          <th className={th}>{t.colRecord}</th>
          {withValue ? <th className={th}>{t.colValue}</th> : null}
        </tr>
      </thead>
      <tbody>
        {list.rows.map((x) => (
          <tr key={x.sourceId} className={row} data-device={x.sourceId}>
            <td className={`${td} font-semibold tabular`}>{x.serial ?? <span className="font-normal text-p4a-muted">{t.noSerial}</span>}</td>
            <td className={`${td} tabular text-p4a-muted`}>{x.sourceId}</td>
            {withValue ? <td className={`${td} tabular`}>{x.value ?? <span className="text-p4a-muted">–</span>}</td> : null}
          </tr>
        ))}
      </tbody>
    </Table>
  );
}
