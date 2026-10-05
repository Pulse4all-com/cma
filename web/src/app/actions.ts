"use server";

import { revalidatePath } from "next/cache";
import { getAccess } from "@/lib/auth/identity";
import { data } from "@/lib/data";

/** End the caller's own workday. The principal comes from the identity seam, never from the client. */
export async function endWorkdayAction(): Promise<void> {
  const access = await getAccess();
  if (!access || access.kind !== "granted") return;
  await data().endWorkday(access.principal, new Date().toISOString());
  revalidatePath("/");
}
