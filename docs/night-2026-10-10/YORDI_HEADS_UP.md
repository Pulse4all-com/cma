# Heads-up to Yordi: the CMA intake track

To: Yordi · From: Martin · Subject: CMA: which customer-related data the Workspace starts receiving

Hi Yordi,

A heads-up, no action needed unless you see a problem. From the coming days, the Contactcenter-Management-App (CMA) starts receiving data from HubSpot, Aircall and Shopify into its own database (Cloud SQL, europe-west4, Pulse4all's Google Cloud). The purpose is operational reporting for the call center: speed to lead, intake per market, call volumes, orders after a lead, and an in-app alert to agents when a new deal arrives. Design: `docs/night-2026-10-10/DESIGN.md` in the CMA repository.

**What is stored** (ids and business facts only):
- HubSpot: deal and ticket ids, pipeline, stage, owner id, amount, source channel, ticket category, created and closed times; contact ids with country, language, currency, Shopify store and the contact's Shopify and NetSuite ids; call engagement ids with time, direction, outcome, duration and owner; which call or deal belongs to which contact; form submission ids with form, time, page (no query string) and campaign tags.
- Aircall: call ids with direction, times, durations, the agent's Aircall id, the line, and tags.
- Shopify (every store): customer ids with order count and amount spent; orders with number, time, amounts, status, sales channel and product lines (SKU, quantity, price).

**What is never stored**: names, email addresses, phone numbers, postal addresses, free text (deal names, ticket subjects, notes, call comments, form answers), recordings. Phone numbers become a keyed hash (secret key per business line) used only to match an Aircall call to its HubSpot call. Emails (from a form, or of a Shopify customer) are used in memory to find the HubSpot contact and then dropped. Shopify gives the app the email field only; it withholds names, phones and addresses itself.

**What the CMA writes into HubSpot**: on the contact a Shopify customer belongs to, the Shopify customer id(s), store, number of orders and amount spent, and country, currency and language only when they are empty. This replaces what Make does today for these fields; every write is logged in the CMA and in HubSpot's property history. The HubSpot app holds read access plus write access on contacts for this.

**Who sees it**: the Workspace shows counts and ids, never customer data; links open HubSpot, where the existing access rules apply. Readers (BigQuery for Joshua's reporting, NocoDB for the build team) see the reporting views with the same ids. I also want to let Claude (Anthropic) query those reporting views through BigQuery, read-only, so I can ask questions about the data; query results then pass through Anthropic, and the views include staff data such as names and working hours. I would start on dev (test data only) and switch it on for prod only if you see no objection. Dev holds test data only.

**Retention**: follows the source. A deletion in HubSpot or Shopify removes the attributes in the CMA; a HubSpot GDPR deletion also clears the hashes linked to that contact. Ids and times remain for counts.

**Also new for you since the last note**: staff ids in other systems (HubSpot owner id, Aircall user id) on each agent's CMA profile, used to attribute calls and speed to lead per agent (the employee-monitoring point we already have open).

Three questions, whenever you have time:
1. Is the purpose (operational reporting and lead alerts) covered by our current processing records for HubSpot, Aircall and Shopify, or does the CMA need its own entry?
2. NocoDB lets the build team browse these ids. Fine as is during the build, or should those views be hidden there?
3. Claude querying the prod reporting views: fine, or under conditions?

Thanks,
Martin
