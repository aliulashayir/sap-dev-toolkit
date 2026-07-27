---
name: sap-odata-rap-integration
description: >-
  Battle-tested playbook for integrating a frontend/BFF with SAP OData V4
  services built on RAP (S/4HANA Public Cloud) via the SAP Cloud SDK for
  JavaScript, and binding the result into a UI5/Fiori (or any) frontend. Use
  whenever the work touches an SAP OData service ($metadata/EDMX, entity sets,
  compositions, value helps), the SAP Cloud SDK (`@sap-cloud-sdk/connectivity`,
  `http-client`, `getDestination`, `executeHttpRequest`), a BFF proxying OData,
  BTP destinations, or wiring create/update/delete forms to an SAP backend — and
  especially when debugging a 400/404/412/500, an opaque "Request failed with
  status code 400", blank form fields, truncated value helps, or amounts/dates
  that save wrong. Reach for it even if the user only says "the save is
  failing", "the OData call errors", "wire this SAP service up", or names
  RAP/CDS/Fiori/BTP without saying "OData". Captures gotchas that cost hours —
  read it before writing the first line of integration code, not after the
  first failure.
---

# SAP OData V4 + RAP + Cloud SDK Integration

Integrating with an SAP OData V4 service (RAP-generated, on S/4HANA Public Cloud
or similar) has a specific set of traps that are invisible until they cost you a
debugging session each. This skill front-loads them.

The service is the source of truth. Its `$metadata` document is a real contract —
richer than the JSON that comes back over the wire. Most integration bugs are one
of: not reading the contract, trusting the declared types at the JS boundary, or
debugging blind because the real error is hidden. The playbook below is ordered
so you hit those in the order they bite.

## The seven rules that prevent most bugs

1. **Read `$metadata` before writing code.** It declares keys, nullability,
   max lengths, and — crucially — *annotations* (semantic units, computed
   defaults, value-list refs, key-as-segment) that change how you must call the
   service. See `references/odata-metadata.md`.

2. **On ANY error, surface the REAL error first — never debug blind.** SAP
   returns a detailed reason in the response *body*; the HTTP status and the
   SDK's `"Request failed with status code 400"` tell you nothing. Extract
   `error.response.data.error.message` before doing anything else. This one
   habit turns hours of guessing into a named, fixable cause. See
   `references/cloud-sdk-bff.md`.

3. **`Nullable="false"` does NOT mean "the client must send it."** RAP defaults a
   surprising number of mandatory fields server-side. The only way to know the
   *true* required set is to POST a minimal payload and read what the service
   actually complains about. Don't pad the body with guessed/derived values —
   that just creates new failure modes.

4. **The declared OData types lie at the JS boundary.** `Edm.Decimal` comes back
   as a JSON *number*, not the string the metadata implies; `Edm.Date` must go
   out as `"YYYY-MM-DD"`, never a localized display string. Normalize on read AND
   on write. See `references/ui-binding.md`.

5. **Semantic pairs travel together.** A measured value can't be sent without its
   unit/currency: `Quantity`↔`UnitOfMeasure`, amount↔`Currency` (driven by
   `@Semantics.*` annotations). Send both or neither, or RAP rejects with
   *"Together with property 'X' also property 'Y' needs to be provided."*

6. **Keys are immutable.** You cannot change a primary key via PATCH (you'll 404,
   because you're addressing a row that doesn't exist). Lock key fields in edit
   UIs, and strip key fields out of PATCH bodies (RAP rejects keys in the
   payload).

7. **Don't invent data the service doesn't have.** Opaque status/type codes with
   no code table, distinctions the model doesn't make (e.g. one currency field,
   not two) — mirror the real source and surface unknowns with a warning. Guessing
   silently corrupts data.

## Error → cause → fix

When something fails, find the symptom here first. Details and code in the
reference files.

| Symptom | Real cause | Fix |
|---|---|---|
| Opaque `"Request failed with status code 400"` (or 500) | SDK swallowed the real error; it's in the response body | Extract `err.response?.data?.error?.message` (also check `err.cause?.response?.data`) and forward THAT — see `cloud-sdk-bff.md` |
| `"Together with property 'Quantity' also property 'UnitOfMeasure' needs to be provided"` | Semantic unit/currency pairing; one half got dropped (e.g. blank unit stripped, zero measure kept) | Send measure+unit and amount+currency atomically — `rap-write-semantics.md` |
| 404 when updating an existing record | A key field was changed, so the PATCH addresses a non-existent row | Lock keys in edit mode; use the full composite key for the lookup — `rap-write-semantics.md` |
| 400 on PATCH mentioning a key/read-only field | Key fields present in the PATCH body | Strip all key fields from PATCH bodies (they belong in the URL only) |
| POST 400 naming a missing mandatory field | A genuinely client-required field is absent | Add ONLY what the error names; re-test. Don't pre-pad from `Nullable="false"` |
| Value-help / dropdown list is truncated (e.g. only 100 rows) | Server-side pagination via `@odata.nextLink`, even with no `$top` | Follow `@odata.nextLink` until exhausted — `cloud-sdk-bff.md` |
| Form fields blank when opening a detail page | Fields never bound to fetched data, or read-boundary type mismatch | Bind `value=`/`onChange`; normalize types on read — `ui-binding.md` |
| `x.trim is not a function` (or similar) on save | A JSON *number* from the service reached string-parsing code | Normalize `Edm.Decimal` → string on read; make parsers accept `string \| number` — `ui-binding.md` |
| Amount saved off by 1000× (or NaN) | Locale decimal parsing mismatch (e.g. `"12.000,50"` vs `"12000.5"`) | Parse locale-aware on write; keep read/write formats consistent — `ui-binding.md` |
| 412 Precondition Required/Failed | Service wants an ETag (`If-Match`) for update/delete | Fetch the entity's ETag and send `If-Match` (or `*` if the service allows) |
| CSRF 403 on a write | Missing/stale CSRF token | Cloud SDK auto-fetches it for write methods by default — don't disable `fetchCsrfToken`; if hand-rolling, GET with `x-csrf-token: fetch` first |

## Workflow: wiring a new entity to a create/update form

This is the sequence that avoids rework. Don't skip step 1 or step 4.

1. **Read the contract.** Pull `$metadata`. For the target entity type(s), build a
   quick field table: name, `Edm.*` type, `Nullable`, `MaxLength`, is-key,
   and any annotations. `references/odata-metadata.md` explains what each
   annotation changes.

2. **Classify the fields.** Keys (immutable, composite?); `ComputedDefaultValue`
   (server-assigned — never send); `@Semantics.*` pairs (unit/currency); value-list
   refs (these need a value-help fetch); compositions/navigation (child entities).

3. **Map types through a normalization boundary.** Read: coerce `Edm.Decimal`
   numbers to strings, dates to display. Write: parse back to JSON numbers /
   ISO dates. Keep your internal model's declared types honest so downstream code
   can trust them. Pattern + helpers in `references/ui-binding.md`.

4. **Discover the true required set empirically.** POST a *minimal* payload (keys
   + the few fields you're sure of). Read the real error. Add only what it names.
   Repeat. This beats reasoning from `Nullable` every time.

5. **Implement the verbs.** Create = POST (deep-insert nested compositions in one
   body if allowed). Update = PATCH (strip keys; compositions usually can't be
   deep-updated via the parent — use per-child POST/PATCH/DELETE against the child
   entity set). Value-helps = fetch following pagination. All in
   `references/rap-write-semantics.md` and `references/cloud-sdk-bff.md`.

6. **Guard the UI.** Lock key fields in edit mode. Validate semantic pairs and
   date/number formats *before* submitting, so the user gets a clear message
   instead of a round-trip 400. `references/ui-binding.md`.

7. **Wire error surfacing end to end** so the real SAP message reaches the user /
   the logs. Do this early — it pays for itself on the first failure.

## Reference files

Read the one that matches what you're doing. Each is self-contained.

- **`references/odata-metadata.md`** — Reading `$metadata`/EDMX: keys & composite
  keys, `Nullable`/`MaxLength`, and the annotations that change your calls
  (`@Semantics.*`, `ComputedDefaultValue`, `KeyAsSegmentSupported`, value lists,
  compositions, capabilities/restrictions). Start here for any new entity.

- **`references/rap-write-semantics.md`** — POST/PATCH/DELETE rules specific to
  RAP: composite keys, deep insert vs. per-child ops for compositions, semantic
  pairing, the `Nullable`≠required truth, immutable keys, KeyAsSegment URLs,
  ETag/If-Match, determinations/validations that mutate your payload server-side.

- **`references/cloud-sdk-bff.md`** — SAP Cloud SDK for JavaScript in a BFF:
  `getDestination` + `executeHttpRequest`, destination auth types (Basic vs.
  principal propagation), CSRF, following `@odata.nextLink`, and — most
  important — extracting the real OData error out of a thrown SDK error.

- **`references/ui-binding.md`** — Binding OData into a frontend (UI5/Fiori
  examples, but the boundary patterns are framework-agnostic): read/write type
  normalization, dates, locale-aware number parsing, value-helps (ComboBox vs.
  Select), locking keys in edit mode, and pre-submit validation mirroring the
  metadata constraints.

- **`references/advanced-topics.md`** — Less-common, high-surprise areas: draft-
  enabled RAP entities (`IsActiveEntity`, Edit/Activate/Discard lifecycle — a plain
  POST only makes a draft!), `$batch` with transactional changesets, `$expand`
  depth/restrictions, and OData actions/functions (the right home for
  approve/submit/post buttons — don't fake them by writing a status field). Read
  when the service is draft-enabled, when you need atomic multi-entity writes, or
  when wiring a workflow action.
