# RAP write semantics — POST / PATCH / DELETE

RAP (ABAP RESTful Application Programming Model) services enforce more rules on
writes than a generic OData service. These are the ones that cause 400/404/412s.

## Discover the required set empirically — don't reason from `Nullable`

RAP *determinations* populate many mandatory fields on the server (timestamps,
fiscal year, derived codes, workflow status, GUIDs). So `Nullable="false"` tells
you the field will be non-null *after* the save, not that the client must send it.

Procedure:
1. POST a **minimal** body: the key fields + the handful you're certain belong to
   the client.
2. Read the *real* error (see cloud-sdk-bff.md — never the bare status).
3. Add ONLY the field(s) the error names. Re-POST.
4. Repeat until it succeeds. That success payload IS the required set.

Why not just send everything? Because padding the body with guessed or derived
values (a company code you inferred, a status code you made up) creates *new*
failures — wrong-value rejections, or silently corrupt records. Send what the
service asks for, nothing more.

## Create = POST, with deep insert for compositions

A composition (owned child collection, e.g. header→items) can usually be created
in one POST by nesting the children under the navigation property:

```jsonc
// POST /Header
{
  "Key1": "...", "Key2": "...", "Key3": "...",
  "SomeField": "...",
  "_Item": [                      // the composition nav property name
    { "MaterialCode": "...", "Quantity": 1, "UnitOfMeasure": "EA", "Currency": "TRY" }
  ]
}
```

If deep insert is rejected, fall back to: POST the parent, then POST each child to
the child endpoint (below).

## Update = PATCH — strip keys, mind the compositions

- **Strip all key fields from the PATCH body.** Keys live in the URL only. RAP
  rejects a PATCH that carries key fields (read-only) in the payload. This is a
  common, confusing 400.
- **You cannot change a key.** If a UI lets the user edit a key field and you
  PATCH with the new value, you're addressing a row that doesn't exist → 404. Lock
  key fields in edit mode (see ui-binding.md).
- **Compositions usually can't be deep-updated through the parent.** Check
  `UpdateRestrictions` → `NonUpdatableNavigationProperties` in the metadata. If the
  child collection is listed there, PATCHing the parent with a nested `_Item`
  array does nothing (or errors). Edit children via their own endpoints.
- PATCH only the fields that changed where possible. Sending unchanged fields is
  usually fine, but sending computed/read-only ones is not.

## Editing children (compositions) on an existing parent

When the parent already exists and you need to change its items, diff current vs.
originally-fetched children and issue per-child calls:

- **New child** → `POST /Parent/key.../_Child` (parent keys in the URL, not the body)
- **Changed child** → `PATCH /Child/parentKeys.../childKey` (strip ALL keys incl.
  the child's own key from the body — they're in the URL)
- **Removed child** → `DELETE /Child/parentKeys.../childKey`

Key the diff on the child's key field (e.g. `ItemNumber`). Note that changing a
child's key reads as delete-old + create-new, since the key *is* the identity.
Fire the calls concurrently, then check for any failure.

## KeyAsSegment URLs

If `KeyAsSegmentSupported` is annotated (see odata-metadata.md), build row URLs as
path segments in key order:

```
/Header/{VendorTaxNumber}/{InvoiceNumber}/{InvoiceDate}
/Item/{VendorTaxNumber}/{InvoiceNumber}/{InvoiceDate}/{ItemNumber}
/Header/{VendorTaxNumber}/{InvoiceNumber}/{InvoiceDate}/_Item   ← POST a new child
```

URL-encode each segment. Confirm the exact shape in the service's Swagger UI if
unsure — it lists every generated verb+path.

## Semantic pairing on write

From `@Semantics` annotations (odata-metadata.md): a measured value requires its
unit/currency in the same body.

- `Quantity` requires `UnitOfMeasure`
- amount fields (`UnitPrice`, `ItemAmount`, `VatAmount`, ...) require `Currency`

The trap: a "drop empty fields" body builder strips a blank unit but keeps a
numeric `0` quantity (0 is not "empty"), orphaning the measure. Enforce the pair
atomically — if the unit is absent, drop the measure too; if currency is absent,
drop the amounts. And validate up front so the user is told, rather than silently
losing the value. Error text: *"Together with property 'X' also property 'Y'
needs to be provided."*

## Opaque codes with no code table

Fields like `Status`, `InvoiceType`, `EinvoiceScenario` are often short SAP codes
with no value-list in the metadata and no documentation on hand. Do NOT invent a
mapping (sending your own UI enum string as the code silently writes garbage).
Options, best to worst:
1. Get the real code list from the backend team / a check table, wire it as a
   value-help.
2. If a field is a placeholder the backend will fill later, confirm with the owner
   and pass the raw value through as a plain string, flagged as provisional.
3. If you must map for display, fall back to a fixed value and `console.warn`
   once per unmapped code so it's visible during testing, never silently wrong.

## ETag / optimistic concurrency (If-Match)

Some RAP services require an ETag for update/delete (412 if missing). Fetch the
entity first, read its ETag (`@odata.etag` or the `ETag` header), and send it as
`If-Match` on the PATCH/DELETE. The Cloud SDK's typed clients handle this for you;
with raw `executeHttpRequest` you pass the header yourself. `If-Match: *` bypasses
the check if the service permits it.

## Determinations & validations can change your data

After a successful write, the server may have recomputed fields (totals, derived
codes, assigned numbers). Re-fetch (or read the response body, which usually
returns the persisted entity) rather than assuming your submitted values stuck.
Don't be surprised when `ItemNumber`, totals, or status differ from what you sent.
