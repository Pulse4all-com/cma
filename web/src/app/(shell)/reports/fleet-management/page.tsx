import { FleetManagement } from "@/components/FleetManagement";
import { resolve } from "@/app/access";

/**
 * Assets → Fleet management (addition 0009t; Martin, 16 November 2026, brief B37): the devices In the field on a map by
 * postcode area, the monitoring-state tiles and the devices that need attention, while the tenant's
 * fleet_management.dummy_preview is on; the placeholder of 15 November 2026 otherwise (components/FleetManagement)
 */
export default async function FleetManagementPage({ searchParams }: PageProps<"/reports/fleet-management">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  return <FleetManagement searchParams={await searchParams} me={r.me} copy={r.copy} />;
}
