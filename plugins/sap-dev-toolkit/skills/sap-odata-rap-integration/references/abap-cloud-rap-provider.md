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

---

## 17. Typing rules that only bite in declarations (extends §15)

§15 covered method parameters. The same "no inline length" rule shows up in two
more places, each with a different error text, so they read like unrelated bugs.

**`RANGE OF` needs a complete type name.**

```abap
DATA lt_keys TYPE RANGE OF c LENGTH 10.     " ✗ '.', 'INITIAL SIZE ...', or
                                            "    'VALUE IS INITIAL' expected after "C"
```

`RANGE OF saknr` works because `saknr` is a data element. `RANGE OF c LENGTH 10`
does not. Declare the row type first:

```abap
TYPES:
  ty_bp_key   TYPE c LENGTH 10,
  tt_bp_range TYPE RANGE OF ty_bp_key.
```

**`RETURNING ... TYPE p LENGTH n DECIMALS n`** → *"A RETURNING parameter must be
fully typed."* ABAP sees only `TYPE p`, which is generic. Same fix: a named type.

Rule of thumb: anywhere a *type* is expected rather than a *variable
declaration*, `c`/`n`/`p`/`x` cannot carry `LENGTH`/`DECIMALS`.

## 18. `Year` and `Month` are reserved words in CDS DDL

```
YEAR is a reserved word (choose another field name)
```

Then, after fixing it, the same for `MONTH`. ADT reports these **one at a time** —
fixing the first is what reveals the second, so budget two round trips.

Date-part names in general (`YEAR`, `MONTH`, `DAY`, …) are reserved. Rename the
CDS element (`ReportYear`, `ReportMonth`) and keep the outbound JSON key via the
serializer's name mapping — the wire contract does not have to follow the element
name:

```abap
( abap = 'YEAR'  json = 'Year' )
( abap = 'MONTH' json = 'Month' )
```

## 19. Inline `@DATA(itab)` is a standard table — `WITH TABLE KEY` then fails

```abap
SELECT glaccount, corporategroupaccount FROM i_glaccountinchartofaccounts
  INTO TABLE @DATA(lt_acc_map).            " standard table, default key
...
READ TABLE lt_acc_map WITH TABLE KEY glaccount = ...   " ✗
```

> The component "GLACCOUNT" is not in key "PRIMARY_KEY" of table "LT_ACC_MAP"
> or the key is not known statically.

Inline declaration cannot carry a key. Declare the hashed/sorted type first and
select `INTO TABLE @lt_acc_map`. Easy to miss because the type is often already
declared and simply unused.

## 20. `MODIFY ... FROM TABLE` and the client column

```
The work area "LT_MAP" is not long enough.
```

A hand-rolled row type that omits the client column is **shorter** than the DB
row, and `MODIFY ... FROM TABLE` requires at least the DB structure's length.
Omitting the field is not how you avoid writing the client.

```abap
TYPES tt_map TYPE STANDARD TABLE OF zfi_hfm_acc_map WITH EMPTY KEY.
" client field present in the structure, left INITIAL;
" ABAP Cloud fills it on write.
```

## 21. A custom entity's key must equal the aggregation key

When the provider aggregates rows, the entity key has to be exactly the grouping
key. If a field is aggregated away but left in the key, either the rows do not
collapse at all, or one arbitrary source value gets stamped onto a summed row.

Worse, duplicate keys in a query result are not a cosmetic problem: FE builds the
row URL from the key, so duplicates make rows overwrite each other, selection
target the wrong row, and an instance action receive an ambiguous key.

Corollary for fields that drop out of the key: **blank them when the group holds
more than one distinct value.** Keeping the first row's value reads as "this
amount came from that account" when it is actually a sum of several.

```abap
IF <ls_agg>-glaccount <> ls_row-glaccount.
  CLEAR <ls_agg>-glaccount.
ENDIF.
```

## 22. `I_CostCenter` is time-dependent — reading it into a hashed table dumps

Key is ControllingArea + CostCenter + **ValidityEndDate**. One cost centre can
have several validity slices, so a direct `INTO TABLE @lt_hashed` keyed on
CostCenter raises a duplicate-key dump on the second slice.

```abap
SELECT costcenter, validityenddate, yy1_globalcostcenter_cos
  FROM i_costcenter
  WHERE validityenddate >= @sy-datum
  ORDER BY costcenter, validityenddate DESCENDING
  INTO TABLE @DATA(lt_raw).

LOOP AT lt_raw INTO DATA(ls_raw).
  " INSERT ... INTO TABLE on a hashed table sets sy-subrc = 4 on a
  " duplicate instead of dumping; ORDER BY makes the first one the current.
  INSERT VALUE #( costcenter = ls_raw-costcenter
                  globalcostcenter = ls_raw-yy1_globalcostcenter_cos )
         INTO TABLE rt_map.
ENDLOOP.
```

Same shape applies to any validity-sliced master data view.

## 23. Custom fields on released views need "Enable Usage" per view

A `YY1_…` field added through Custom Fields & Logic is not visible to ABAP SQL on
a released view (`I_CostCenter`, `I_JournalEntryItem`, …) until that view is ticked
in the field's *Enable Usage* list. The failure is a plain "field unknown" at
compile time, which reads like a typo. The fix is in the Fiori app, not in ADT.

## 24. 404 vs 403 on a service URL

Testing a published service by hand separates two failures that look identical
from the UI ("app could not be opened", empty list):

| Response | Meaning |
|---|---|
| **404** on `$metadata` | The service is not registered — binding not published |
| **403** | Service exists, the user lacks the business catalog / role |

Worth knowing: maintenance objects generated by Business Configuration
Maintenance Object reach their UI through the Business Configuration framework
and need **no separate publish**, while a plain custom RAP UI service does. Seeing
an unpublished maintenance binding work is not evidence that publishing is
optional for your own service.

## 25. Key user Custom Logic BAdIs are `FUNCTIONAL` — every `SELECT` needs `WITH PRIVILEGED ACCESS`

Activating a Custom Logic implementation that reads a CDS view fails at syntax
check with:

```
Executing "Unprivileged SQL" from "CHANGE" violates transactional contract "FUNCTIONAL".
```

This is not an authorization problem. In ABAP Cloud every extension point
carries a **transactional contract**; most key user BAdIs are classified
`FUNCTIONAL`, meaning the implementation is expected to be side-effect free.
Under that classification a plain `SELECT` counts as "unprivileged SQL" and the
compiler rejects it — no role, no catalog entry and no IAM change will help.

The fix is a language addition, per data source, **including every JOIN branch**:

```abap
SELECT SINGLE CharcInternalID
  FROM I_ClfnCharacteristicForKeyDate WITH PRIVILEGED ACCESS
  WHERE Characteristic = @lc_charc
  INTO @DATA(lv_charc_id).

SELECT SINGLE clfn~CharcValue
  FROM I_BatchDistinct AS bat WITH PRIVILEGED ACCESS
  INNER JOIN I_ClfnObjectCharcValForKeyDate AS clfn WITH PRIVILEGED ACCESS
    ON clfn~ClfnObjectInternalID = bat~ClfnObjectInternalID
  WHERE bat~Batch = @ls_item-batch
  INTO @lv_value.
```

Forgetting it on a single JOIN branch reproduces the same error, and the message
names the contract rather than the offending line — so on a multi-source query,
check every `FROM` and every `JOIN`.

**The addition goes before the alias, not after it.** `FROM I_BatchDistinct AS bat
WITH PRIVILEGED ACCESS` fails with `"WITH" is not allowed here. "." is expected.`
and then, because the statement never parsed, every inline `@DATA()` it declared
is reported as an unknown field — three errors from one misplaced keyword. A
source without an alias hides the mistake, since there is nothing for the
addition to come after.

`WITH PRIVILEGED ACCESS` only unlocks **reading**. Writing (`INSERT`, `UPDATE`,
`MODIFY`, `DELETE`) stays closed under `FUNCTIONAL`, which is correct: a key user
BAdI changes the document through its `CHANGING` parameter and lets the framework
do the persisting. If you find yourself wanting a direct write, the logic belongs
somewhere else.

SAP Notes 3434597 and 3364262.

## 26. Classification values are reached by internal ID, never by name

`I_ClfnObjectCharcValForKeyDate` carries `CharcInternalID` and `CharcValue` but
**no** `Characteristic` field — writing `WHERE Characteristic = 'Z_BRIX'` fails
with `unknown column name`. The technical name (`ATNAM`) lives only on the
characteristic master view; the value views are kept narrow and join for the
name.

Resolve the ID once, outside the loop, then filter values by it:

```abap
SELECT SINGLE CharcInternalID
  FROM I_ClfnCharacteristicForKeyDate WITH PRIVILEGED ACCESS
  WHERE Characteristic = @lc_charc
  INTO @DATA(lv_charc_id).

IF sy-subrc <> 0 OR lv_charc_id IS INITIAL.
  RETURN.
ENDIF.
```

Two things fall out of this. The lookup happens once per call instead of once per
item, and a missing characteristic is detected before any item is touched.

Characteristic type decides which column holds the value. A `CHAR` characteristic
fills `CharcValue` (`ATWRT`); a `NUM` one leaves it empty and puts the number in
`CharcFromDecimalValue` (`ATFLV`, paired with `...To...` because numeric
characteristics can hold a range). Reading only `CharcValue` against a numeric
characteristic returns blank with `sy-subrc = 0` — a hit, no value. The screen
gives the type away: a value rendered with a unit, like `27.000 %`, is `NUM`.
Read both columns and prefer the decimal one.

Always filter `ClassType` as well — `023` is batch classification, `001` is
material. The same characteristic name can exist in both classes, and without the
filter the wrong value is returned silently.

Reaching a batch's values needs one more hop: `I_BatchDistinct` translates
material + batch into `ClfnObjectInternalID` (SAP Note 3244147). There is no view
that goes from batch number straight to characteristic value.


## 27. Adobe Forms: `calculate` on a data-bound field is overwritten by the data

A computed field whose value must derive from other data — a division, a sum, a
concatenation — looks like a job for the field's `calculate` event. On a field
that is **bound to a data node**, it is not: the XFA event order is

```
initialize  →  DATA BINDING  →  calculate  →  validate  →  ...  →  form:ready
```

and binding wins. The script runs, writes `this.rawValue`, and the bound value
lands on top of it. The printed output shows the raw data, not the computed
result, with no error anywhere — the most convincing kind of silent failure,
because the field *is* populated, just not with your number.

Use `form:ready` instead, which fires after binding:

```xml
<event activity="ready" ref="$form" name="event__ready_total">
   <script contentType="application/x-javascript" runAt="server">
```

`runAt="server"` stays mandatory — the XFA default is `client`, and a client
script never executes in the PDF ADS renders for printing. A form can carry
several `initialize` scripts that have never run once in production for exactly
this reason; their presence is not evidence that scripting works.

Two ways to tell the failure modes apart on the printout: a field showing the
**raw bound value** means the script ran in the wrong event, while a field
showing **nothing** means either the binding is wrong or the script never ran.
Keeping one known-working server script in the same form is the cheapest
control — if it still behaves, the mechanism is fine and the fault is local.


## 28. `invocationGrouping` is a UI annotation, not a BDEF addition

Without it, Fiori Elements calls an action **once per selected row**; a user
who selects 32 rows triggers 32 round trips. The fix belongs in the metadata
extension, on the action's UI entry:

```abap
@UI.identification: [ { type: #FOR_ACTION, dataAction: 'approveAll',
                        label: 'Approve', invocationGrouping: #CHANGE_SET } ]
```

Writing it in the behavior definition instead —

```abap
action ( features : instance, invocationGrouping : #CHANGE_SET ) approveAll;
```

— fails with `Unexpected character "#"`, which reads like a typo and sends you
looking for a stray symbol rather than a misplaced clause. The BDEF's
parenthesised list holds feature control and authorization only.

The two halves are easy to confuse because they describe the same behaviour
from different sides: the BDEF says what the action *is*, the annotation says
how the UI *invokes* it.

## 29. Turning a root entity into a composition child: the activation check misses most of it

Converting `A` from a root into a child of a new root `B` is a handful of CDS
edits — and then a long tail of objects that still assert "A is a root". None of
them fail activation. All of them fail at runtime, in front of the user.

The CDS and BDEF side is the part the compiler helps with:

- root view: drop `root`, add `association to parent`
- new root: add `composition [1..*] of A`
- projection: `_Parent : redirected to parent`
- BDEF: one `define behavior` per entity, child gets `lock dependent by` and
  `authorization dependent by`
- delete the old BDEFs and old behavior pools — a behavior pool that names a
  now-child entity will not activate

What the compiler does **not** check, and what therefore has to be walked
manually:

| Object | What still says "root" | Symptom |
|---|---|---|
| Access controls (DCL) | own conditions, or a `REPLACING { ROOT WITH _Assoc }` naming an association you deleted | `ACM_UNEXPECTED_VALUE` dump on read (§31) |
| `@ObjectModel.sapObjectNodeType` | registered on what is now a child | runtime errors in object-model-aware infrastructure |
| Service definition | `@ObjectModel.leadingEntity` points at the child | §34 |
| Metadata extension | `dataAction` entries for actions that moved to the header | activation fails, but only once you touch the MDE |
| Draft tables | rows left from the old BO | Edit dumps forever (§32) |
| Jobs / batch classes | `TYPE TABLE FOR CREATE <child>` | child has no standalone create |
| Existing data | items with no header row | orphans; the BO cannot read them, the list comes up empty |

The last row is the one that gets mistaken for a bug in the new UI. Items that
predate the restructure have no parent, and a composition BO cannot read a child
without its root. The list is empty, the metadata extension looks wrong, and the
real fix is a one-off backfill that inserts the missing header rows.

Run the backfill **before** opening the new screen. Otherwise the first thing you
see is an empty list, and you will spend the next hour on the UI layer.

## 30. Derived types: `root\Alias` is not a path, and `root\_Assoc` is only for create-by-association

Two spellings exist and only one of them is a path:

```abap
" create THROUGH the composition - uses the ASSOCIATION
DATA lt_create TYPE TABLE FOR CREATE zr_order\_Item.

" read / update / delete the child - uses the CHILD ENTITY'S OWN NAME
DATA lt_update TYPE TABLE FOR UPDATE zr_item.
```

There is no `TYPE TABLE FOR UPDATE zr_order\Item`. Both wrong spellings —
with and without the underscore — produce the same message:

```
The type "ZR_ORDER\ITEM" is not an entity for which BEHAVIOR can be defined.
```

which reads as a problem with the *entity* and sends you back to the BDEF to
check whether the child's behavior is defined properly. It is not; the type
expression is.

The rule behind it: a create-by-association payload has to carry the parent key
plus the child rows (`%cid_ref`, `%key`, `%target`), so it needs the path. An
update payload carries the child's own complete key, so the parent is irrelevant
and the entity names itself. Being a child restricts an entity's *operations*;
it does not stop the entity having a name.

EML statements are a separate grammar and keep the association form:
`READ ENTITIES OF zr_order ENTITY Order BY \_Item` is correct and unaffected.

## 31. A DCL that references a deleted association fails at runtime, never at activation

Access controls are compiled against the CDS entity, but they are **not**
re-checked when that entity changes. Delete an association and the view
activates clean; the DCL that navigated it is now broken and says nothing.

The classic shape is a projection role that remaps the inherited root condition:

```abap
define role ZC_ITEM {
  grant select on ZC_ITEM
  where INHERITING CONDITIONS FROM ENTITY ZR_ITEM REPLACING { ROOT WITH _BaseEntity };
}
```

`_BaseEntity` is a self-referencing association that exists for exactly this
purpose and looks like dead weight during a cleanup. Removing it leaves the DCL
pointing at nothing, and the failure surfaces as an `ACM_UNEXPECTED_VALUE` short
dump the first time a user opens the list — with no mention of the association,
the role, or the view.

Two habits avoid it:

- run a **Where-Used List** before deleting any CDS element, associations
  included; "looks unused" is not evidence, and DCLs do not show up in the
  places you normally look
- when restructuring a BO, treat the DCL set as part of the model. A composition
  wants the real condition on the root and inheritance below it:

```abap
define role ZR_ORDER { grant select on ZR_ORDER where TRUE; }
define role ZR_ITEM  { grant select on ZR_ITEM
                       where INHERITING CONDITIONS FROM ENTITY ZR_ORDER; }
define role ZC_ORDER { grant select on ZC_ORDER
                       where INHERITING CONDITIONS FROM ENTITY ZR_ORDER; }
define role ZC_ITEM  { grant select on ZC_ITEM
                       where INHERITING CONDITIONS FROM ENTITY ZR_ITEM; }
```

A view with `@AccessControl.authorizationCheck: #MANDATORY` and no DCL at all is
the other half of the same trap — easy to create when you add a new root and
forget it needs its own role.

## 32. Stale draft rows block Edit permanently, and a restructure creates them wholesale

A RAP draft table's primary key is the **business key**, not a UUID. That is
deliberate: one draft per business object, so two users cannot edit the same
record. The consequence is that a draft row which outlives its owner locks that
record's Edit button for good:

```
CL_CSP_ACT_DRAFT_OP_ON_DB -> LIF_DB_ACCESS~COPY_ACTIVE_TO_DRAFT
CX_SY_OPEN_SQL_DB: a data record is to be inserted even though a data record
                   with the same primary key already exists
```

Edit copies active → draft; the copy is an `INSERT`; the key is taken.

Normally the user clears their own leftovers with Discard. After a BO
restructure they cannot: the drafts belong to an entity shape that no longer
exists, so nothing reaches them. Every Edit dumps.

Empty the draft tables as part of the restructure, child first:

```abap
DELETE FROM z_item_d.
DELETE FROM z_order_d.
COMMIT WORK AND WAIT.
```

This destroys unsaved user work, so count before you delete and do it in a
test system first. Put draft tables on the restructure checklist (§29) —
they are easy to forget precisely because they hold no data you care about.

## 33. `result [1] $self` and `RESULT result` must agree, and the error lands on the wrong object

An action declared in the BDEF with a result:

```abap
action ( features : instance ) createOrder result [1] $self;
```

requires the handler method to declare one:

```abap
METHODS createOrder FOR MODIFY
  IMPORTING keys FOR ACTION Order~createOrder RESULT result.
```

Mismatched, the message is:

```
"RESULT field" was expected, not "".
```

reported against the **behavior pool**, at the method declaration line. The
object that actually needs changing is usually the BDEF, and nothing in the
message points there. Worse, if the two were edited at different times you can
end up with a result on some actions and not others, and only the mismatched
one complains — which looks like a problem specific to that action.

Decide once for the whole BO. `result [1] $self` is only worth declaring if the
handler genuinely fills it; a declared-but-unfilled result is a long-lived
"why is this empty" question. Screen refresh after an action is a job for
`side effects`, not for the result:

```abap
side effects
{
  action createOrder affects entity _Item, $self;
}
```

Also note that a BDEF edited but not activated leaves the handler compiling
against the *previously active* version, so the error can persist after you have
already fixed it. Activate the BDEF first, then the class.

## 34. `leadingEntity` in an `odata_v4_ui` service must be a root entity

A service definition carries the entry point for the Fiori Elements app:

```abap
@ObjectModel.leadingEntity.name: 'ZC_ORDER'
define service ZUI_ORDER
  provider contracts odata_v4_ui {
    expose ZC_ORDER as Order;
    expose ZC_ITEM  as Item;
  }
```

After a restructure this still names the old root, which is now a child. Fixing
it is one line, and it is the line that also decides which list the existing
tile opens — Fiori Elements takes the leading entity as the app's main entity
set, so a correct `leadingEntity` plus a republished binding usually saves you
from editing the app descriptor at all.

Keep the child exposed. Dropping it from the service breaks navigation into the
composition and the item table in the object page comes up empty.

And the binding has to be **republished**: it stores a snapshot of `$metadata`
taken at publish time, so activating CDS changes nothing until you publish
again. Most "I added the field but OData does not return it" reports are this.

## 35. A determination with `{ create; }` also fires when a draft is opened

`on modify { create; field X; }` reads as "when the user creates a record". In a
draft-enabled BO it also runs when the user presses **Edit**, because Edit
creates the draft instance by copying the active one.

That matters twice:

- **Side effects.** A determination that defaults a field will run against
  existing records every time somebody opens them, not only against new ones.
  Guard on the field already being filled, or the user's own entry gets
  overwritten on the next Edit:

```abap
IF ls_item-Plant IS NOT INITIAL.
  CONTINUE.   " user typed it - do not overwrite
ENDIF.
```

- **Cost.** One `SELECT` per child row inside the determination becomes one per
  row of the whole composition, on every Edit. Read the children in a single
  set-based statement and match in memory instead.

## 36. Moving actions from item to header: the conditions you lose are the negative ones

When a header-level button replaces a per-item one, the feature control has to
re-derive from the children what used to be a property of one row. Positive
conditions translate naturally — "an order exists" becomes "some item has an
order". The dangerous ones are the conditions phrased as an absence.

Item-level code frequently queries its own siblings to express them:

```abap
SELECT ... WHERE order_no = @key-order_no
             AND item_no <> @key-item_no
             AND goods_receipt_status IS INITIAL
  INTO TABLE @DATA(lt_other_items).
...
%action-postGoodsIssue = COND #( WHEN ... AND lt_other_items IS INITIAL ... )
```

That sibling query is a smell worth reading carefully rather than deleting: it
means the decision was always a header decision. `lt_other_items IS INITIAL` is
**all items are done**, and the obvious header translation — "some item is done"
— is a different, weaker rule that silently enables the button too early.

Collect both polarities while looping the children and spell the condition out:

```abap
IF ls_item-GoodsReceiptStatus = abap_true.  lv_gr_some = abap_true. ENDIF.
IF ls_item-GoodsReceiptStatus = abap_false. lv_gr_missing = abap_true. ENDIF.
...
%action-postGoodsIssue = COND #(
  WHEN lv_gr_some = abap_true AND lv_gr_missing = abap_false   " ALL, not ANY
  THEN if_abap_behv=>fc-o-enabled ELSE if_abap_behv=>fc-o-disabled )
```

Carry the explanatory message across too. A disabled button with no reason is a
support call; `%state_area` messages are how the old code told the user which
shipment it was waiting on. State messages persist until cleared, so append an
empty entry for the area before conditionally appending the real one:

```abap
APPEND VALUE #( %tky = ls_key-%tky %state_area = 'NO_GR' ) TO reported-order.
IF <condition>.
  APPEND VALUE #( %tky = ls_key-%tky %state_area = 'NO_GR'
                  %msg = new_message( ... ) ) TO reported-order.
ENDIF.
```

Without the clearing append the message stays on screen after the user fixes
the cause.

## 37. `@Metadata.ignorePropagatedAnnotations: true` silently drops value helps written in CDS

A projection declared with

```abap
@Metadata.ignorePropagatedAnnotations: true
define view entity ZC_Item as projection on ZR_Item
```

ignores every annotation inherited from the base view. A
`@Consumption.valueHelpDefinition` written on `ZR_Item` therefore never reaches
the service: no error, no warning, the field simply has no F4 and the search
help you carefully configured is invisible.

The annotation exists so a projection can own its UI contract outright, and it
is on by default in a lot of generated code — including projections that were
generated years earlier by somebody else.

With it set, value helps, labels and UI annotations belong in the **metadata
extension**, not in the CDS:

```abap
@Consumption.valueHelpDefinition: [{ entity: { name: 'I_Plant', element: 'Plant' },
                                     useForValidation: true }]
Plant;

@Consumption.valueHelpDefinition: [{ entity: { name: 'I_StorageLocation',
                                               element: 'StorageLocation' },
                                     useForValidation: true,
                                     additionalBinding: [{ localElement: 'Plant',
                                                           element: 'Plant',
                                                           usage: #FILTER }] }]
StorageLocation;
```

The `additionalBinding` with `usage: #FILTER` is what keeps a dependent help
dependent. Drop it and the user is offered every storage location in the client
rather than the ones belonging to the plant they just picked — a defect that
only shows up when somebody picks the wrong one.

Check for this annotation first whenever an F4 fails to appear. It is a one-line
cause with no diagnostic, and it looks nothing like a value help problem.
