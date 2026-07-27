---
description: Parse an SAP OData $metadata (EDMX) into a field map — keys, Edm types, MaxLength, nullability, and the annotations that change how you must call the service.
argument-hint: "[path or URL to the $metadata / EDMX document]"
---

Load the `sap-odata-rap-integration` skill and follow its `references/odata-metadata.md`.

Read the OData `$metadata` here: $ARGUMENTS

For each EntityType being integrated, produce a table of: property name · Edm type ·
Nullable · MaxLength · is-key · annotations. Then explicitly call out:

- the **composite key** shape, and whether `KeyAsSegmentSupported` is set;
- **computed / read-only** fields (`Core.Computed`, `ComputedDefaultValue`) that must NOT be sent on write;
- **semantic pairs** (`@Semantics` unit/currency) that must travel together;
- **value-help sources** (referenced entity sets / `ValueList`) and whether they paginate (`@odata.nextLink`);
- whether the entity is **draft-enabled** (`IsActiveEntity` key / `DraftRoot`);
- **filter/sort restrictions** and whether `$search` is available.

Copy property names verbatim — casing is often inconsistent (e.g. entity set `UnitofMeasure`, property `UnitOfMeasure`).
