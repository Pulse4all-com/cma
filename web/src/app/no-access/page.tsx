import { connection } from "next/server";
import { config } from "@/lib/config";
import { t } from "@/lib/copy";
import { NoAccess } from "../access";

// A recognised account without an active app_user row lands here (README,
// Authentication). No Shell, no data: the person may not work yet.
export default async function NoAccessPage() {
  await connection();
  return <NoAccess copy={t(config.defaultLocale)} />;
}
