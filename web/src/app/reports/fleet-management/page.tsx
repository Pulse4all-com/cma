import { PlaceholderPage } from "@/components/PlaceholderPage";
import { resolve } from "../../access";

/**
 * Fleet management, a placeholder page of the rail (Martin, 15 November 2026; decision D5 extended to whole pages, as the
 * pages of 13 November): its purpose, what will feed it and its definition status, never a figure or customer data
 * (components/PlaceholderPage)
 */
export default async function FleetManagementPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  return <PlaceholderPage which="fleetManagement" me={r.me} copy={r.copy} />;
}
