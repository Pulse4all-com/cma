/**
 * The HubSpot adapter as the server sees it: authenticate a request, map its body to canonical
 * events, read objects back. Route: POST /hubspot/<connection key>.
 */
import { getSecret } from "../../core/secrets.mjs";
import { verifyV3 } from "./verify.mjs";
import { mapEvents } from "./map.mjs";
import { readBack } from "./read.mjs";

export const hubspot = {
  name: "hubspot",

  /** v3 signature with the app's client secret; SecretUnavailable propagates (the server answers 500). */
  async authenticate({ method, uris, body, headers, connection }) {
    const secret = await getSecret(connection.signingSecretName);
    return verifyV3({ method, uris, body, headers, secret });
  },

  /** The authenticated body → canonical events; throws SyntaxError on a body that is not JSON. */
  mapRequest(body, connection) {
    return mapEvents(JSON.parse(body.toString("utf8")), connection.externalAccountId);
  },

  readBack,
};
