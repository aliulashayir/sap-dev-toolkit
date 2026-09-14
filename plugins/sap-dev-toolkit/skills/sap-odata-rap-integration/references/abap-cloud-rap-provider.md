# Building the provider side: ABAP Cloud, custom entities, RAP actions

The rest of this skill assumes SAP owns the service and you consume it. This file
is the other half: **you are writing the RAP service**, in developer extensibility
(embedded steampunk) on S/4HANA Public Cloud. Different traps, same property —
each one is invisible until it costs a session.

Ordered by when it bites you.

---

## 1. Check the release contract before you design anything

A standard CDS view is only usable in your code if its **API State** says
`Use in Cloud Development: Yes`. Open it in ADT → Properties → API State.

Three contracts, and they mean different things:

| Contract | Grants |
|---|---|
| C0 Extend | Extension, not consumption |
| C1 Use System-Internally | ABAP SQL + CDS views — **this is the one you need** |
| C2 Use as Remote API | Stable OData/remote API |

`Use in Cloud Development: No` on C1 means the view does not exist for your code,
even though ADT can display it and Data Preview works.

**A "requires the parameter X" error is not proof the view is usable.** ADT runs
the syntax check before the release check. Fill the parameters and the real error
appears. Verify the contract first; do not infer it from an error message.

## 2. When the view you need is closed

A view can be C1-closed *and* still reachable over HTTP as an OData service (that
is how the Fiori app in front of it works). The release contract restricts
**compile-time binding**, not network calls.

So the system calling its own OData API is a legitimate escape hatch. Note what
you are accepting:

- If C2 is not set and the service has no API catalog assignment, SAP makes no
  stability promise. Field names and behavior can change on upgrade and you have
  no claim. Write this down in the spec — it will outlive your memory of it.
- The call leaves the system and comes back in. You need **both** directions
  configured (see §9). "It's our own API" does not make it internal.

## 3. Custom entity + query provider

A custom entity has no table behind it; an ABAP class produces the rows.

```abap
@ObjectModel.query.implementedBy: 'ABAP:ZCL_MY_QUERY'
define root custom entity ZC_MY_REPORT { ... }
```

**Symptom:** `FETCH API (direct DB access) is not supported for entity ZC_...`
**Cause:** the framework did not find a query implementation, so it fell back to
reading the database — and there is no table.
**Check first:** is `@ObjectModel.query.implementedBy` in the **active** version
of the entity? Losing that one line during an edit produces exactly this error,
and it looks like a binding/framework problem, not a missing annotation.

Confirm with a breakpoint in `if_rap_query_provider~select`. If the debugger
never stops, the provider is not wired — do not go looking anywhere else.

## 4. Behavior definition on a custom entity

- The entity must be `define **root** custom entity`. A BDEF on a non-root
  entity is rejected.
- The ADT template arrives with `create` / `update` / `delete` / `lock master` /
  `authorization master`. For a read-only report, **delete all of it**. In an
  unmanaged BO every declared operation must be implemented, and each one shows
  up as a button in Fiori Elements.
- Reads still go through the query provider. The BDEF governs writes and actions
  only.

**Symptom:** `RAISE_SHORTDUMP` / `SYNTAX_ERROR` at runtime, in
`ZBP_..._CCIMP`, saying *"ZC_... is not an entity with authorization check"*
**Cause:** the ADT-generated handler contains `get_global_authorizations FOR
GLOBAL AUTHORIZATION`, but the BDEF does not declare `authorization master`.
**Fix:** delete the method, or declare the authorization. Either is fine; they
must agree.

The important part: **this is not caught at activation.** The behavior pool is
generated on first call. "Everything is active" does not mean it runs.

## 5. Raising an error out of a query provider

`CX_RAP_QUERY_PROVIDER` is **abstract** — you cannot raise it.
`CX_RAP_MESSAGE_ERROR` is **not released** for cloud development.

So you create your own subclass. SAP's own applications do the same
(`CX_SD_RAP_PROVIDER_QUERY`, `CX_WLF_RAP_QUERY_PROVIDER`, …) — one per
application. An empty subclass is the normal pattern, not a smell.

Generate it with **New > ABAP Class → Superclass `CX_RAP_QUERY_PROVIDER`**. The
wizard writes a constructor that wires `if_t100_message~t100key`; a hand-written
empty body does not activate.

Raising is the only way to abort a query, and it produces HTTP 500 — so put a
real message class behind it. The alternative (returning an empty table) is
worse: the user cannot tell "no data" from "the backend is down".

## 6. Paging is enforced — but you can raise the page size the FE asks for

```abap
DATA(lv_page_size) = io_request->get_paging( )->get_page_size( ).
```

Returning more rows than *requested* dumps with `CX_RAP_QUERY_PAGE_SIZE_OVERRUN`
— *"Query implementation returned too many records"*. The provider can never
hand back more than the current request's `$top`; that ceiling is not
negotiable from the provider side, no matter where the data came from (live
call, cache, staging table — doesn't matter, the limit is per-response, not
per-data-source).

What you *can* do is make the frontend ask for more in its first request, so
the growing table never needs a second round-trip. On the **custom entity
itself** (not the metadata extension — annotation is ignored there for this
one) put:

```abap
@UI.presentationVariant: [{ maxItems: 500, visualizations: [{ type: #AS_LINEITEM }] }]
define root custom entity ZC_MY_REPORT
```

This raised the FE's initial `$top` to 500 and the scroll-to-load-more step
disappeared entirely for a ~450-row report — one request, one response, done.
Two things this does *not* do: it does not lift the overrun ceiling (asking for
1000 rows the provider can't supply within `maxItems` still dumps), and it does
not make the underlying `SELECT`/API call any cheaper — if the query itself is
slow, `maxItems` just moves the wait from "look for a scrollbar" to "wait for
the first draw."

Consequence for actions regardless: do not design around Fiori's *Select All*,
which only ever covers rows already loaded into the table. Have the action
derive its scope from **one** row's key and rebuild the full set server-side
(see §8) — that way the number of rows selected, or even loaded, never affects
what actually gets processed.

## 7. Sorting silently does nothing if you skip `to_upper`

Fiori sends element names as written in the entity (`GLAccount`). Dynamic
`SORT itab BY (sort_tab)` wants the **component** name, uppercase. Mismatch =
no sort, no error.

```abap
ls_order-name = to_upper( ls_sort-element_name ).
```

Also: pick a default sort over fields that are always filled. Sorting by a field
that is empty on most rows looks like the sort is broken.

## 8. Static action vs instance action

A **static** action cannot see the filter bar. RAP does not pass the query filter
to actions, so the user has to re-enter the selection in a popup — and if they
type something different, the action operates on data that is not on screen.
Silent, and entirely avoidable.

An **instance** action receives the selected rows' keys. Derive the scope from a
key and rebuild server-side:

```abap
READ TABLE keys INTO DATA(ls_key) INDEX 1.
lv_gjahr = ls_key-Period(4).      " key encodes what you need
lv_monat = ls_key-Period+5(2).
```

One selected row is enough, the popup disappears, and what the user sees is what
gets processed.

## 9. Outbound communication is a four-object chain

To call anything from ABAP Cloud, in this order:

1. **Outbound Service** (ADT) — a *separate repository object*. The field in the
   communication scenario is a picker, not a definition. Skip this and you get
   *"Outbound Service ID does not exist"*.
2. **Communication Scenario** (ADT) — add the outbound service, pick auth
   methods, activate, then **Publish Locally**. Without publishing, the scenario
   never appears in the Fiori Communication Arrangements app — and no error says so.
3. **Communication System** (Fiori) — host, port, credentials.
4. **Communication Arrangement** (Fiori) — scenario + system. Saving it creates
   the application destination that `create_by_comm_arrangement` looks up.

```abap
CONSTANTS:
  c_comm_scenario TYPE c LENGTH 30 VALUE 'Z_...',   " C(30)
  c_service_id    TYPE c LENGTH 40 VALUE 'Z_...'.   " C(40), not 30

cl_http_destination_provider=>create_by_comm_arrangement(
  comm_scenario = c_comm_scenario
  service_id    = c_service_id ).                   " comm_system_id optional
```

`string` constants are rejected — the parameters are fixed-length.

Direction traps:

- A communication system with **`Inbound Only`** ticked cannot be an outbound
  destination. Reusing an existing inbound system will not work.
- The **Users for Outbound Communication** list stores *credentials you present*.
  It does not create or authorize anything. When the target is your own tenant,
  that user must also exist as an **inbound** user with rights to the service —
  two configurations, one user. Missing the inbound half gives 401/403 at the
  first real call, after the arrangement saved cleanly.
- An arrangement is identified by **scenario + system**, so the same standard
  scenario can back several arrangements with different systems. That is how you
  give an integration its own credentials without editing someone else's config.

**Why not just `create_by_url`:** the host encodes the tenant
(`my123456-api...`, `...-dev-...`). Transported to QA it keeps pointing at DEV,
runs happily, and reports nothing. Credentials in source also mean rotation
requires a transport — and rotating a shared user breaks whoever else hardcoded it.

## 10. Close the HTTP client in the error path too

```abap
CATCH cx_root INTO DATA(lx).
  IF lo_client IS BOUND.
    TRY.
        lo_client->close( ).
      CATCH cx_root ##NO_HANDLER.
    ENDTRY.
  ENDIF.
```

Every failed attempt leaks a connection. Once the pool is exhausted, an
*unrelated* call starts returning HTTP 500 and you debug the wrong component.
The happy path usually has `close( )`; the error path is the one that runs
repeatedly in production.

## 11. Reading a failure that came back through middleware

SAP Integration Suite wraps everything it cannot handle in one envelope:

```
An internal server error occured: The MPL ID for the failed message is : AGqin...
```

The status code carries no information — a CSRF rejection, a mapping failure and
a script exception all arrive as 500. **The MPL ID is the diagnostic**: Monitor →
Message Processing Logs. Hand it over instead of the status code.

Corollary: do not rule out CSRF because "that would be a 403". If the endpoint's
HTTPS adapter has *CSRF Protected* on, fetch a token first — `GET` with
`X-CSRF-Token: Fetch`, then send it on the `POST`. Reuse the same client so the
session cookie travels with it.

## 12. Small things that cost real time

- **OData V2 responses paginate.** Follow `d.__next` in a loop or you silently
  get the first page. `Edm.Decimal` arrives as a *string* — convert via
  `decfloat34`.
- **Turkish/non-ASCII characters are stripped from object names** by ADT.
  "Şirket Kodu" becomes `IRKETKODU`. Keep identifiers ASCII; put the local
  language in `@EndUserText.label` and descriptions.
- **Action buttons in Fiori Elements** go in an *element's* `@UI.lineItem` array
  as a second entry, not at entity level:
  ```abap
  @UI.lineItem: [ { position: 10 },
                  { type: #FOR_ACTION, dataAction: 'sendToCpi', label: 'Send' } ]
  ```
- **Business Configuration maintenance objects** give you a maintenance UI with
  no code (ADT → Business Configuration Maintenance Object wizard), reached via
  *Custom Business Configurations*. Visibility needs an IAM app; without one the
  object simply does not appear in the list.
- **A business role does not always pick up a newly added catalog.** Recreating
  the role is the cheapest first test — cheaper than hunting authorization
  objects for an hour.
- **Republish the service binding** after changing an entity. Metadata is cached;
  the old shape survives an activation and you debug a fixed bug.

## 13. "Query not fully covered" — a 501 that looks like empty data

RAP requires the provider to **handle every feature of the request**, not merely
return rows. If the request carries `$orderby` and you never call
`io_request->get_sort_elements( )`, RAP rejects the whole call:

```
HTTP 501   RAP_RUNTIME/004
Query not fully covered by implementation:
Call to method if_rap_query_request~get_sort_elements missing
```

Fiori Elements renders that as **"No data"** — visually identical to an empty
result set. That mislabeling cost a full debugging session: the debugger showed
four rows in the internal table with `set_data( )` about to execute. The data was
fine; the response never reached the frontend.

Handle all of these in *every* provider, including a four-row value help:

- `get_sort_elements( )` → build `abap_sortorder_tab`, `SORT ... BY (tab)`
- `get_filter( )->get_as_ranges( )` inside `TRY`, catching `cx_rap_query_filter_no_range`
- paging: `get_paging( )` → offset trim + page-size trim
- `is_total_numb_of_rec_requested( )` → `set_total_number_of_records( )`
- search: implement it, or put `@Search.searchable: false` on the entity so
  `$search` is never sent — the cheapest way to not implement a feature

Rule of thumb: **every `get_*` you don't call is a latent 501.** Copy the whole
block when you write a new provider; the one you skip is the one the framework
asks for.

## 14. Domain fixed values do not give you an F4 in OData V4

In classic SAP GUI a domain's fixed values produce a value help for free. In
RAP/OData V4 they do not — Fiori Elements builds value help from the `ValueList`
annotation in `$metadata`, and domain fixed values never get there.

What you actually need:

1. A value help entity. For a handful of constant values a custom entity whose
   query provider returns them hard-coded is the least work — `DD07L` is not
   released in ABAP Cloud, so do not try to read the domain at runtime.
2. `@Consumption.valueHelpDefinition: [{ entity: { name: 'ZC_..._VH', element: 'Code' } }]`
   on the consuming field — on the **entity (Data Definition)**, not the metadata
   extension. In an MDE it produces a parser error at the annotation's colon.
3. `expose ZC_..._VH;` in the **service definition**. Skip this and the entity is
   absent from `$metadata`; the F4 fails silently, with no error anywhere.
4. Republish the service binding.

`@ObjectModel.resultSet.sizeCategory: #XS` makes FE render a dropdown instead of
opening a value-help dialog.

FE calls value help through a **separate F4 service**, which is how you recognize
the request in the network tab:

```
.../odata4/sap/<binding>/srvd_f4/sap/<vh_entity>/0001;ps='srvd-<service>-0001';va='...<field>'/$batch
```

Seeing that URL with `200 OK` means the wiring is right — any remaining failure
is inside the batch payload (see §13; a 501 hides in there and shows as "No data").

**Chicken and egg:** the entity names the class in `@ObjectModel.query.implementedBy`
while the class types its table off the entity. Neither activates first. Activate
the class with an empty body (`METHOD if_rap_query_provider~select. RETURN. ENDMETHOD.`),
activate the entity, then fill the class in.

## 15. ABAP syntax rules that only bite in provider code

- **Inline `TYPE c LENGTH n` is illegal in a method signature.** Valid in `DATA`,
  `CONSTANTS` and structure components; not in `IMPORTING`/`RETURNING`. Declare a
  named type (`TYPES ty_quarter TYPE c LENGTH 2.`) and use that. The error text
  is unhelpful: `Unable to interpret "2"`.
- **Parameter blocks have a fixed order:** `IMPORTING → EXPORTING → CHANGING →
  RETURNING → RAISING`. Writing `RETURNING` before `EXPORTING` gives
  `"." , "RAISING", "OPTIONAL" ... expected after TY_X` — an error that points at
  the type, not at the ordering.
- **`RETURNING` + `EXPORTING` on the same method blocks functional calls.**
  `DATA(x) = cls=>m( ... )` is rejected; you need the procedural form with
  `RECEIVING`. Usually the better fix is to drop `EXPORTING` and return one
  structure — the call sites stay readable and the signature stops being fragile.

## 16. Leading zeros: NUMC re-pads what you just stripped

`SHIFT lv LEFT DELETING LEADING '0'` does nothing visible on a NUMC (`n`) field.
The type cannot hold a blank, so the gap opened on the right refills with `'0'`
immediately. Convert first, then shift:

```abap
DATA(lv_code) = CONV string( ls_row-some_numc_field ).
SHIFT lv_code LEFT DELETING LEADING '0'.
```

The same trap waits at the *other* end: if the structure you append into declares
that field as NUMC, the cleaned value is re-padded on assignment and the JSON
payload ships `0000010001` again. Both the working variable **and** the target
field have to be plain character types.

Where this hurts: a CDS view's element type is inherited from DDIC, so
`VALUE i_glaccountinchartofaccounts-corporategroupaccount( ... )` hands you NUMC
without saying so. Check the type of the intermediate variable, not just the
entity field you can see in the CDS source.
