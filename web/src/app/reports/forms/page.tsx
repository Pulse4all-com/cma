import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { AnswerFilters, FormsFilters } from "@/components/FormsFilters";
import {
  AnswersTable, categoryLabel, FormsChart, FormsDateLine, FormsGroupSwitch, FormsTable, FormsTotals, marketLabel, ResolutionBars,
} from "@/components/FormsParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FormsGroup } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  fmtCount, fmtPct, formsByCategory, formsByMarket, formsFilterQuery, formsLines, formsSeries, formsSum, MAX_REPORT_DAYS, parseAnswerFilter,
  parseFormsFilter, parseFormsGroup, REPORT_PERMISSIONS, resolvedShare,
} from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Forms (Report, addition 0008p, brief B17d): every polled form's submissions for a period, whether or not
 * the form counts as leads in Intake (README Decision log, 16 October 2026), per day or ISO week (G), narrowed
 * by market (K), category (Y) and form (F). A submission's market is the form's own, else the answer to its
 * market field read through the market aliases, else its contact's country, else unknown. Four tiles: the
 * submissions and the forms with submissions, each with its change against the previous period in Muted text
 * with an arrow, like for like (as Calls: while the period runs, against the same point in the previous one;
 * before the tenant's forms history "No history to compare yet"); the share of contacts found and the
 * submissions without a market. Then the submissions per day or week as columns, the forms per market with
 * the previous period, the change and the resolution split, the totals per category and per market, how the
 * contacts were found, and the kept choice answers with the previous period and question and answer filters.
 * The table downloads as a file in the tenant's export format (X). Shown to people holding reports.view or
 * performance.team; the database checks again on every read. A tenant without forms sees "No forms
 * received", never 0. Form names, category and market codes, option values and counts only: no submission,
 * no contact, no email address, no free-text answer. Every tile and header explains itself in a hint.
 */
export default async function FormsPage({ searchParams }: PageProps<"/reports/forms">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.forms;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="forms">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: FormsGroup = parseFormsGroup(sp.group) ?? "day";
  const { filter, problem } = parseFormsFilter(sp.market, sp.category, sp.form);
  const answer = parseAnswerFilter(sp.field, sp.value);
  const narrowed = answer.field !== null || answer.value !== null;
  const [report, answers, allAnswers] = await Promise.all([
    data().getFormsReport(me, period, group, filter),
    data().getFormsAnswers(me, period, filter, answer.field, answer.field === null ? null : answer.value),
    // the question and answer lists come from every kept answer of the period, so a choice never empties its own list
    narrowed ? data().getFormsAnswers(me, period, filter, null, null) : null,
  ]);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const pageQuery = { ...periodQuery, group, ...formsFilterQuery(filter) };
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);
  const prev = { previousFrom: report.previousFrom, historyStart: report.historyStart };

  const lines = formsLines(report.totals, report.previous);
  const sum = formsSum(report.totals);
  const previousSubmissions = report.previous.reduce((a, x) => a + x.submissions, 0);
  const formsNow = new Set(report.totals.map((x) => x.formKey)).size;
  const formsBefore = new Set(report.previous.map((x) => x.formKey)).size;
  const marketsNow = new Set(report.totals.map((x) => x.market)).size;
  const categoriesNow = new Set(report.totals.map((x) => x.category ?? "none")).size;
  const unknown = report.totals.filter((x) => x.market === "unknown").reduce((a, x) => a + x.submissions, 0);
  const share = resolvedShare(sum);
  const fieldLists = [...new Map((allAnswers ?? answers).rows.map((x) => [x.field, new Set<string>()])).entries()].map(([field]) => ({
    field, values: [...new Set((allAnswers ?? answers).rows.filter((x) => x.field === field).map((x) => x.value))].sort(),
  })).sort((a, b) => a.field.localeCompare(b.field));

  const h = copy.hints;
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text });
  const n = (x: number) => fmtCount(x, me.locale);
  const delta = (current: number, previous: number) =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} />;
  const download = `/api/v1/reports/forms/export?${new URLSearchParams({ from: period.from, to: period.to, ...formsFilterQuery(filter) }).toString()}`;

  return (
    <Shell copy={copy} me={me} active="forms" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/forms" range={range} period={period} today={today} copy={copy} keep={{ group, ...formsFilterQuery(filter) }} />
        </div>
        {report.forms ? (
          <div className="mb-6">
            <FormsFilters markets={report.markets} categories={report.categories} forms={report.formList} filter={filter}
              query={{ ...periodQuery, group }} copy={copy} />
          </div>
        ) : null}
      </div>

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}
      {problem || answer.problem ? (
        <div className="mb-6">
          <Notice tone="warning">{t.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <FormsGroupSwitch group={group} query={{ ...periodQuery, ...formsFilterQuery(filter) }} copy={copy} />
        <div className="flex items-end gap-4">
          <FormsDateLine from={period.from} to={period.to} filter={filter} categories={report.categories} forms={report.formList} copy={copy} locale={me.locale} />
          {report.forms && !invalid ? (
            <LinkButton href={download} download shortcut="X" data-shortcut="x" title={t.downloadHint} data-testid="forms-download">{t.download}</LinkButton>
          ) : null}
        </div>
      </div>

      {!report.forms ? (
        <Card>
          <p className="text-body" data-testid="forms-not-connected">
            <NotConnected label={copy.reports.noForms} hint={copy.reports.noFormsHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noFormsHint}</span>
          </p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section className="grid grid-cols-4 gap-4" aria-label={t.title} data-testid="forms-tiles">
            <CallsTile testId="forms-submissions" label={t.submissions} value={n(sum.submissions)} info={info(t.submissions, h.formsSubmissions)}
              detail={t.submissionsDetail.replace("{forms}", n(formsNow)).replace("{markets}", n(marketsNow))} delta={delta(sum.submissions, previousSubmissions)} />
            <CallsTile testId="forms-forms" label={t.formsWithSubmissions} value={n(formsNow)} info={info(t.formsWithSubmissions, h.formsForms)}
              detail={t.formsDetail.replace("{categories}", n(categoriesNow))} delta={delta(formsNow, formsBefore)} />
            <CallsTile testId="forms-resolved" label={t.resolved} value={fmtPct(share === null ? null : share * 100, me.locale)} info={info(t.resolved, h.formsResolvedShare)}
              detail={t.resolvedDetail.replace("{resolved}", n(sum.resolved)).replace("{submissions}", n(sum.submissions))} />
            <CallsTile testId="forms-without-market" label={t.withoutMarket} value={n(unknown)} info={info(t.withoutMarket, h.formsWithoutMarket)}
              detail={t.withoutMarketDetail.replace("{unknown}", n(unknown)).replace("{submissions}", n(sum.submissions))} />
          </section>

          <Card title={group === "day" ? t.chartDay : t.chartWeek}>
            {report.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <FormsChart series={formsSeries(report.rows, group, period.from, period.to, today)} group={group} copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={t.tableTitle}>
            {lines.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <FormsTable lines={lines} categories={report.categories} prev={prev} copy={copy} locale={me.locale} />
            )}
          </Card>

          {lines.length === 0 ? null : (
            <div className="grid grid-cols-1 gap-6 min-[1800px]:grid-cols-2">
              <Card>
                <FormsTotals title={t.byCategory} label={t.category} labelHint={h.formsCategory} totalHint={h.formsCategoryTotal} testId="forms-by-category"
                  rows={formsByCategory(lines, report.categories).map((x) => ({ key: x.code ?? "none", label: categoryLabel(x.code, report.categories, copy), submissions: x.submissions, previous: x.previous }))}
                  prev={prev} copy={copy} locale={me.locale} />
              </Card>
              <Card>
                <FormsTotals title={t.byMarket} label={t.market} labelHint={h.formsMarket} totalHint={h.formsMarketTotal} testId="forms-by-market"
                  rows={formsByMarket(lines).map((x) => ({ key: x.market, label: marketLabel(x.market, copy), submissions: x.submissions, previous: x.previous }))}
                  prev={prev} copy={copy} locale={me.locale} />
              </Card>
            </div>
          )}

          <Card title={t.resolutionTitle}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.resolutionIntro}</p>
            {sum.submissions === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <ResolutionBars lines={lines} copy={copy} locale={me.locale} />}
          </Card>

          <Card title={t.answersTitle}>
            <div className="-mt-2 mb-4 flex flex-wrap items-end justify-between gap-4">
              <p className="max-w-3xl text-small text-p4a-muted">{t.answersIntro}</p>
              {fieldLists.length > 0 || narrowed ? (
                <AnswerFilters fields={fieldLists} field={answer.field} value={answer.field === null ? null : answer.value} query={pageQuery} copy={copy} />
              ) : null}
            </div>
            {answers.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.answersEmpty}</p> : (
              <AnswersTable rows={answers.rows} copy={copy} locale={me.locale} />
            )}
          </Card>
        </div>
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
