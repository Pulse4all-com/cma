import { connection } from "next/server";
import { getIdentity } from "@/lib/auth/identity";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";
import { switchAccountHref } from "@/lib/logout";
import { NoAccess } from "../access";

// A recognised account without an active app_user row lands here (README,
// Authentication). No Shell, no data: the person may not work yet. Since 11 October 2026 the
// page shows the person their own account id, the one Add a person on People asks for, so a
// new agent can read it to the manager instead of anyone looking it up elsewhere. With the signed-out page in
// place (CMA_LOGOUT_TARGET=signed-out) it also offers "Use another account".
export default async function NoAccessPage() {
  await connection();
  const identity = await getIdentity();
  return <NoAccess copy={t(config.defaultLocale)} identity={identity} switchHref={switchAccountHref(config.logoutTarget)} />;
}
