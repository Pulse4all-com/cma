import { connection } from "next/server";
import { getAccess } from "@/lib/auth/identity";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";
import { data } from "@/lib/data";
import { dateKeyInZone, fmtTime } from "@/lib/time";

// After IAP cleared its cookie the browser lands here. With one Google account
// in the browser the login is silent, so this page must not open a workday:
// it only reads today's state and says what happened.
export default async function LoggedOutPage() {
  await connection();
  const access = await getAccess();
  const copy = t(access?.kind === "granted" ? access.principal.locale : config.defaultLocale);

  let endedAt: string | null = null;
  if (access?.kind === "granted") {
    const me = access.principal;
    const today = await data().getWorkday(me, dateKeyInZone(new Date(), me.timeZone));
    if (today?.endedAt) endedAt = fmtTime(today.endedAt, me.timeZone, me.locale);
  }

  return (
    <div className="flex h-full items-center justify-center bg-p4a-sand p-8">
      <div className="max-w-md">
        <h1 className="text-title font-bold text-p4a-heading">{copy.logOut.doneTitle}</h1>
        <p className="mt-3 text-body">
          {endedAt ? `${copy.myDay.endedAt} ${endedAt}. ${copy.logOut.doneBodyToday}` : copy.logOut.doneBody}
        </p>
      </div>
    </div>
  );
}
