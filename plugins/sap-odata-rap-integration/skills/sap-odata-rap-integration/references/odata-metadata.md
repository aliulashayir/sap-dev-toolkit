# Reading `$metadata` (EDMX) — the contract

`GET <service-root>/$metadata` returns an EDMX document. It is richer than any
response body and is the authoritative contract. Read it before writing code;
re-read the relevant entity when a call fails unexpectedly.

Fetch it as XML. In a pinch, the service's Swagger/OpenAPI UI (if RAP exposes
one) shows the same entities and the exact URL shapes for each verb — very handy
for confirming key-as-segment paths and which child operations exist.

## Build a field table first

For each `EntityType` you touch, extract every `<Property>` into a table:

| Column | From | Why it matters |
|---|---|---|
| Name | `Property@Name` | The wire field name — case-sensitive, use verbatim |
| Type | `Property@Type` | `Edm.*` — drives boundary normalization (see ui-binding.md) |
| Nullable | `Property@Nullable` | `false` ≠ client-required (see below) |
| MaxLength | `Property@MaxLength` | Enforce in validation to pre-empt a 400 |
| Precision/Scale | on `Edm.Decimal` | Decimal shape; `Scale="variable"` is common |
| Key? | listed in `<Key><PropertyRef>` | Immutable; part of the URL for row-addressing |
| Annotations | `<Annotations Target="...">` | The part everyone forgets — see below |

## Keys and composite keys

```xml
<EntityType Name="HeaderType">
  <Key>
    <PropertyRef Name="VendorTaxNumber"/>
    <PropertyRef Name="InvoiceNumber"/>
    <PropertyRef Name="InvoiceDate"/>
  </Key>
  ...
```

- A single-field key is the easy case. **Composite keys are the norm in RAP** and
  they bite: a lookup by one field ("find invoice 12345") is an assumption that
  may not be unique. Your route/URL must carry the *full* key to address a row
  deterministically.
- Keys are immutable. Changing any key part means you're addressing a different
  (probably non-existent) row → 404. See rap-write-semantics.md.

## Annotations — what actually changes your calls

Annotations live in `<Annotations Target="Namespace.Type/Property">` blocks (and
some target the type or container). These are the highest-value part of the
metadata because they silently dictate correct behavior.

### `@Semantics` unit/currency pairing

```xml
<Annotations Target="...ItemType/Quantity">
  <Annotation Term="...measures.Unit" Path="UnitOfMeasure"/>
</Annotations>
<Annotations Target="...ItemType/UnitPrice">
  <Annotation Term="...measures.ISOCurrency" Path="Currency"/>
</Annotations>
```

A measured value is bound to a unit/currency field. **You must send them
together.** If you build the body by dropping empty fields, you can strip the
unit while keeping a `0` quantity, which orphans the measure → RAP 400
*"Together with property 'Quantity' also property 'UnitOfMeasure' needs to be
provided."* Treat measure+unit and amount+currency as atomic pairs.

### `ComputedDefaultValue` / `Computed`

```xml
<Annotations Target="...ItemType/ItemNumber">
  <Annotation Term="...Core.ComputedDefaultValue"/>
</Annotations>
```

The server assigns this if you omit it. For line-item numbers etc., prefer
omitting and letting the server number them. `Core.Computed` (read-only, e.g.
`CreatedBy`, `CreatedAt`, `...LastChanged*`) must never be sent on write.

### Value lists (value-helps)

Look for `Common.ValueList` / `ValueListReferences`, or a dedicated reference
entity set (e.g. `Currency`, `UnitofMeasure`). These back dropdowns. Two gotchas:
- The reference entity set often **paginates server-side** (`@odata.nextLink`)
  even with no `$top`. Follow every page or the dropdown is silently truncated.
- **Casing is exact and sometimes inconsistent** — e.g. entity set `UnitofMeasure`
  (lowercase 'o') but property `UnitOfMeasure` (uppercase 'O'). Copy names
  verbatim from the actual response, don't assume.

### `KeyAsSegmentSupported`

```xml
<Annotation Term="...Capabilities.KeyAsSegmentSupported"/>
```

When present, address rows with path segments — `/Header/key1/key2/key3` — not the
parenthesized `/Header(...)` form. The Swagger UI confirms which the service
expects. Order of segments follows the key order in `<Key>`.

### Capabilities & restrictions

`Capabilities.*` annotations on the container/entity declare what's allowed:
- `InsertRestrictions` / `UpdateRestrictions` / `DeleteRestrictions` — whether a
  verb is even permitted, and which properties are non-updatable.
- `NonUpdatableNavigationProperties` — e.g. a composition (`_Item`) that CANNOT be
  deep-updated through the parent's PATCH. This is why item edits on an existing
  parent need per-child calls (see rap-write-semantics.md).
- `FilterRestrictions` / `SortRestrictions` / `FilterFunctions` — which `$filter`
  operators and which properties are usable. Don't assume `contains`, `$orderby`,
  etc. are supported on every field; the metadata lists what is.

## `Nullable="false"` is not "client must provide"

This is the single most expensive false assumption. RAP determinations fill many
mandatory fields server-side (entry timestamps, fiscal year, derived company
codes, workflow status, GUIDs...). A field can be `Nullable="false"` and still be
something you must NOT send (computed) or need not send (defaulted).

The reliable way to learn the true client-required set: **POST a minimal payload
and read the real error** (see the workflow in SKILL.md and error extraction in
cloud-sdk-bff.md). Reason from the service's actual responses, not from
`Nullable`.

## Compositions vs. associations

- A **composition** (`<NavigationProperty>` with `ContainsTarget`/parent-child, or
  a `Composition` annotation) is an owned child collection — e.g. header→items.
  Created together (deep insert) but often NOT deep-updatable via the parent.
- A plain **association** is a reference to an independently-managed entity.

Knowing which you have decides whether children ride along in the parent body or
need their own endpoint.
