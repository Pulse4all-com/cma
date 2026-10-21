import Link from "next/link";
import { SourceConfig } from "@/components/configuration/SourceConfig";
import { SourceKindRules } from "@/components/configuration/SourceKindRules";
import { SourceReasons } from "@/components/configuration/SourceReasons";
import { Card } from "@/components/primitives";
import { data } from "@/lib/data";
import { CmaDbError } from "@/lib/data/errors";
import { sourceSections } from "@/lib/sources";
import { resolve } from "../../../access";
import { ConfigurationPage, mayConfigure } from "../../gate";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * One connection (Configuration → Sources, addition 0008e): its own fields, settings and the sections its
 * kind has. An id that is not a connection of the tenant shows a calm page, never another tenant's data. Since addition
 * 0008zb a connection with customer records shows its reasons and its record kind rules after its sections
 */
export default async function SourcePage({ params }: { params: Promise<{ id: string }> }) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configSources;
  const { id } = await params;
  if (!mayConfigure(me)) {
    return <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro}>{null}</ConfigurationPage>;
  }
  let detail = null;
  if (UUID_RE.test(id)) {
    try {
      detail = await data().getSource(me, id.toLowerCase());
    } catch (e) {
      if (!(e instanceof CmaDbError && e.sqlState === "CMA02")) throw e;
    }
  }
  if (!detail) {
    return (
      <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro} bare>
        <Card title={t.notFoundTitle}>
          <p className="text-body">{t.notFoundBody}</p>
          <Link href="/configuration/sources" className="mt-4 inline-block text-small font-semibold text-p4a-deepblue hover:underline">← {t.back}</Link>
        </Card>
      </ConfigurationPage>
    );
  }
  const { markets } = await data().getMarkets(me);
  // the form categories (addition 0008p), for a form's category
  const categories = await data().getFormCategories(me);
  // the connected-call threshold (addition 0008j), shown in words on a telephony connection
  const settings = await data().listSettings(me);
  const threshold = settings.find((x) => x.key === "telephony.connected_min_seconds")?.value;
  // the tenant's email settings (addition 0008t), shown in words on a CRM connection
  const valueOf = (key: string) => settings.find((x) => x.key === key)?.value ?? null;
  const numberOf = (v: string | null) => (v === null || v === "" ? null : Number(v));
  const email = {
    startDate: valueOf("email.start_date") || null, replyTargetMinutes: numberOf(valueOf("email.reply_target_minutes")),
    noResponseDays: numberOf(valueOf("email.no_response_days")), marketOrder: valueOf("email.market_order"),
  };
  // the reasons and the record kind rules (addition 0008zb), for a connection with customer records
  const crm = sourceSections(detail.connection.kind, detail.connection.heldKinds).includes("fields");
  const kinds = crm ? await data().getRecordKinds(me) : [];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-sources" title={`${t.title}: ${detail.connection.name}`} intro={t.intro} bare trail={[{ label: detail.connection.name }]}>
      {/* keyed by the settings, so the editor starts again from the database's answer after a save */}
      <SourceConfig key={JSON.stringify(detail.connection.settings)} detail={detail} markets={markets} categories={categories} copy={copy} locale={me.locale} timeZone={me.timeZone}
        connectedMinSeconds={threshold === undefined ? null : Number(threshold)} email={email} />
      {crm ? <SourceReasons key={`reasons:${JSON.stringify(detail.fields)}`} detail={detail} copy={copy} /> : null}
      {crm ? <SourceKindRules detail={detail} kinds={kinds} copy={copy} /> : null}
    </ConfigurationPage>
  );
}
