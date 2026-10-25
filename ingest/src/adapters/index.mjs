/**
 * The adapters by route name. A route exists only for an adapter registered here, and a connection
 * answers only on its own adapter's route (DESIGN §5). Shopify since brief B10; Trusted Shops since brief B18,
 * polling only (kind poll: no route answers for it).
 */
import { hubspot } from "./hubspot/index.mjs";
import { aircall } from "./aircall/index.mjs";
import { shopify } from "./shopify/index.mjs";
import { automation } from "./automation/index.mjs";
import { trustedshops } from "./trustedshops/index.mjs";

/** automation (0008a) is a message route, not a webhook: the server hands it the body as messages */
export const ADAPTERS = { hubspot, aircall, shopify, automation, trustedshops };
