---
description: Debug an SAP OData / RAP / Cloud SDK failure (400/404/412/500, opaque "Request failed with status code 400", blank fields, truncated value helps, amounts/dates saving wrong) using the error→cause→fix map.
argument-hint: "[paste the error, or describe the failing call]"
---

Load the `sap-odata-rap-integration` skill.

The failure: $ARGUMENTS

Work it in this order:

1. **Surface the real error first.** If it's the opaque "Request failed with status code
   400" (or any SDK-level message), the actual reason is in the response body, not the
   status. Extract `err.response?.data?.error?.message` (also check
   `err.cause?.response?.data`) before doing anything else — never debug blind.
2. Match the symptom against the skill's **error → cause → fix** table.
3. State the most likely cause and the concrete change (with file:line if you can see the code).

Watch for the usual culprits: swallowed errors, `Edm.Decimal` arriving as a JSON number,
non-ISO dates, key fields in a PATCH body, an unpaired semantic unit/currency, unfollowed
`@odata.nextLink`, a changed composite key, or a draft-enabled entity where a plain POST
only made a draft.
