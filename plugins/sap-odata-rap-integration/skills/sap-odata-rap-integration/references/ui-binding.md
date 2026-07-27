# Binding OData into a frontend

Examples use UI5 Web Components for React (SAP Fiori), but the *boundary* patterns
— normalize on read, normalize on write, validate before submit — are
framework-agnostic and are where the subtle data bugs live.

## The declared types lie — normalize at the boundary

The single richest source of frontend bugs: trusting `$metadata`'s declared types
at runtime. TypeScript interfaces you write from the metadata describe the
*contract*, but the JSON over the wire doesn't always match, and your form inputs
have their own type needs.

- **`Edm.Decimal` comes back as a JSON `number`**, even though it reads like a
  string field. If your model declares it `string` and a component calls
  `.trim()`/`.toLowerCase()` on it, you get `x.trim is not a function` at runtime
  — TypeScript never caught it because the declared type was a lie.
- **`Edm.Date` must go out as `"YYYY-MM-DD"`**. Date pickers hand you a *localized
  display* string (`"20.07.2026"`); sending that fails `Edm.Date`.

Fix it once, at the read and write boundary, so the rest of the app can trust the
model's declared types:

```ts
// READ boundary: coerce whatever the service sent into the string your model claims.
function toStr(v: string | number | undefined | null): string | undefined {
  return v === undefined || v === null || v === '' ? undefined : String(v);
}

// WRITE boundary: parse a form string back to a JSON number for the wire.
// Accepts number too, because a fetched value may round-trip through state
// untouched — guard against calling string methods on it.
function toNumber(v: string | number | undefined | null): number | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  if (typeof v === 'number') return Number.isNaN(v) ? undefined : v;
  const t = v.trim();
  // Locale-aware: a comma means the decimal separator (e.g. tr-TR "12.000,50").
  // No comma → treat as a plain numeric string ("12000.5"). Getting this wrong
  // silently scales values by 1000× on round-trip.
  const normalized = t.includes(',') ? t.replace(/\./g, '').replace(',', '.') : t;
  const n = Number(normalized);
  return Number.isNaN(n) ? undefined : n;
}
```

Apply `toStr` in every raw→model mapper (detail, list rows, child items). Apply
`toNumber` for every `Edm.Decimal` field when building a write body. Keep read and
write locale formats consistent so an untouched fetched value round-trips
unchanged.

Dates: convert display→ISO on the picker's change handler, ISO→display on the
value prop, so component state is always ISO:

```ts
function toIsoDate(display?: string): string {          // "20.07.2026" → "2026-07-20"
  const m = display?.match(/^(\d{2})\.(\d{2})\.(\d{4})$/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : (display ?? '');
}
// <DatePicker value={toDisplay(state.date)} onChange={e => set(toIsoDate(e.detail.value))}/>
```

## Bind fetched data — don't leave inputs uncontrolled

A classic "the detail page is blank" bug: the page fetches data for the title but
the form inputs are static/uncontrolled (no `value=`). Every editable field needs
`value={state.field}` + an `onChange`/`onInput` that writes back to state, and a
one-time sync from the fetched record into state once it arrives (data loads async,
after first render — an effect keyed on the fetched data, not initial state).

## Value-helps: ComboBox vs. Select

Back dropdowns with the real reference entity set (following pagination — see
cloud-sdk-bff.md), not a hardcoded list.

- **Select** — fine for short, fixed lists (a handful of options).
- **ComboBox** — use when the list is long (dozens to hundreds; e.g. units of
  measure, currencies). Type-to-filter is essential past ~20 entries. In UI5 React
  it's `ComboBox` + `ComboBoxItem` (`text=`); the `change` event carries the picked
  value on `e.target.value`.

If the model has one field but the mockup shows two inputs for it (e.g. a single
`Currency` behind both "invoice currency" and "payment currency"), bind BOTH to
the one real value — don't invent a distinction the data doesn't support.

## Lock key fields in edit mode

Keys are immutable (see rap-write-semantics.md). If the form is reused for create
and edit, make key fields editable only on create:

```tsx
<Input readonly={!isCreate} value={...} onInput={...} />
```

Otherwise a user edits the key, you PATCH, and it 404s against a row that doesn't
exist — a confusing failure that looks like a backend problem but is a UI one.

## Validate before submit, mirroring the metadata

A pre-submit check gives the user a clear, local message instead of a round-trip
400 — and makes testing far faster. Mirror the constraints you read from
`$metadata`:

- **Composite key present** (all parts, on create).
- **Semantic pairs**: if a non-zero measure is entered, its unit is required
  (block); a zero/blank measure can be dropped by the write-boundary guard instead
  of nagging the user.
- **Format**: dates ISO, digit-sequence fields (`IsDigitSequence`) digits-only.
- **`MaxLength`** on each string field.

Keep the messages in your i18n layer if the app is localized. Errors block submit;
warnings inform without blocking. This validation is a convenience/UX layer — the
server is still the real authority, so always surface its error too (it will catch
things the client can't know).

## Belt-and-suspenders: guard the write body too

Even with validation, make the body-builder itself refuse to emit a broken payload
— e.g. after dropping empty fields, re-drop an orphaned measure whose unit is gone,
and amounts whose currency is gone (semantic pairing). Validation is the UX; this
guard guarantees correctness for any path that bypasses it (and prevents silent
data loss the user never sees — so pair a silent guard with a visible validation
message for the same rule).
