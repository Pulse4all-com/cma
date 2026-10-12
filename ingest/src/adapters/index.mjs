/**
 * The adapters by route name. A route exists only for an adapter registered here, and a connection
 * answers only on its own adapter's route (DESIGN §5). Aircall (brief B9) and Shopify (brief B10)
 * plug in here.
 */
import { hubspot } from "./hubspot/index.mjs";
import { automation } from "./automation/index.mjs";

/** automation (0008a) is a message route, not a webhook: the server hands it the body as messages */
export const ADAPTERS = { hubspot, automation };
