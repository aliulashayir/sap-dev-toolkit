---
description: Scaffold a value-help end to end for an SAP OData reference entity set — a BFF route that follows @odata.nextLink pagination, a typed data hook with a mock fallback, and a filterable ComboBox bound to the field.
argument-hint: "[entity set name, e.g. Material / Currency / UnitofMeasure]"
---

Load the `sap-odata-rap-integration` skill.

Wire a value-help for the OData entity set: $ARGUMENTS

Mirror the project's existing value-help pattern (look at how Currency/UnitofMeasure/Material
are wired, if present):

1. **BFF route** that reads the entity set following `@odata.nextLink` to the last page —
   reference data paginates server-side even with no `$top`, so a single fetch silently
   truncates the list. (See `references/cloud-sdk-bff.md`.)
2. **Data hook** returning the values, with a mock fallback for local dev and a sensible cache.
3. **Filterable ComboBox** (not a plain Select — these lists run long) bound to the field.

Copy the entity set and key/property names verbatim from `$metadata` — casing is often
inconsistent. Confirm the field is exposed and the list isn't `Searchable=false` if you
need search. (See `references/ui-binding.md` for the ComboBox.)
