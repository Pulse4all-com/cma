import { emailParams } from "@/lib/api/email";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The email report (cma.email_report, addition 0008t) for ?from&to (at most 92 days), &group=day|week (day when
 * left out; anything else 400) and the optional &market (a code or unknown), &inbox and &account (connection
 * id ':' source id) filters: `rows` per day or week, `total` and `previous` (the previous equal period, like
 * for like) with received, logged replies, agent sends, automated, bounced and failed, conversations opened and
 * closed, first replies (medians in elapsed and business seconds, within the target, without business hours)
 * and the time to close; the same per inbox, mailbox, category and market; the received messages per date and
 * inbox and per date and mailbox; `waiting` (conversations waiting now) and `notResponding` (open lead deals),
 * each capped by follow_up.list_rows with its total; `historyStart`; the settings the hints name; the lists for
 * the filters; and `email` (false: no inbox and no email, and no rows, never 0). Needs reports.view or
 * performance.team, here and again in the database. Ids, codes, counts and times only: no subject, address or name.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = emailParams(new URL(request.url).searchParams);
    return ok(await data().getEmailReport(me, range, group, filter));
  });
}
