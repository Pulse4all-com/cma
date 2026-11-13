import { PlaceholderPage } from "@/components/PlaceholderPage";
import { resolve } from "../../access";

/**
 * A placeholder page of the rail (Martin, 13 November 2026; decision D5 extended to whole pages): its purpose, what will
 * feed it and its definition status, never a figure or customer data (components/PlaceholderPage)
 */
export default async function PurchaseOrdersPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  return <PlaceholderPage which="purchaseOrders" me={r.me} copy={r.copy} />;
}
