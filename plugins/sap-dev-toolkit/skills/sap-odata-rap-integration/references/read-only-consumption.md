# Consuming OData V4 read-only: monitoring, reporting, log analysis

The rest of this skill assumes a form: you read an entity, the user edits it, you
write it back. This file is the other shape — you pull **large volumes** out of
SAP log/report entities, aggregate them, and never write. Dashboards, error
monitors, reconciliation tools, anything that answers "how many, how bad, since
when".

Different shape, different traps. Nothing here is about PATCH or validation; all
of it is about **reading a lot without silently reading the wrong amount**.

The examples are Python/`httpx` because the Cloud SDK is JavaScript-only and this
shape of consumer is often a Python/Java service. The traps are
language-independent.

---

## 1. `$top` is a hard cap, not a page size

The single most expensive mistake in this shape. `$top=1000` in a paging loop
looks like "give me a page of 1000" and behaves like "never give me more than
1000 — ever".

```python
# ✗ Silently truncates every pull to the first 1000 rows.
params = {"$top": 1000}
# The server returns exactly 1000 and — because it delivered what was asked —
# emits NO @odata.nextLink. The loop sees "no next link" and declares success.
```

Page with `$skip` and a bounded loop instead:

```python
rows, skip = [], 0
while len(rows) < max_rows and skip < page_size * max_pages:
    page = get(path, params={**base, "$skip": skip, "$top": page_size})
    batch = page["value"]
    rows += batch
    if len(batch) < page_size:
        break                      # short page = last page
    skip += page_size
```

**Why it hides:** 1000 rows is plausible. Nobody counts. The dashboard is wrong
by a factor that depends on the real row count, and it is wrong consistently, so
it looks like data rather than a bug.

**Detect it:** ask for `$count=true` once and compare against what you pulled. If
your pull is exactly your page size, you have this bug.

---

## 2. `$apply` may be a 501 — and the fallback can starve

`$apply` (`groupby`, `aggregate`) is optional in OData V4 and plenty of RAP-
generated services reject it:

```
HTTP 501   /IWBEP/CM_V4S_RUN/002
```

The obvious fallback — one big sweep, count in your own code — has a failure mode
that is worse than the 501 because it returns a plausible number:

> **Starvation.** A single pull is capped (`max_rows`). If one key dominates the
> table, the cap fills with that key's rows and every other key legitimately
> counts **zero**. The screen says "no errors" for integrations that have
> thousands.

Count per key instead, with `$count` and `$top=0`:

```python
def count_for(key):
    r = get(path, params={"$filter": filt(key), "$count": "true", "$top": 0})
    return int(r["@odata.count"])
```

One request per key, each cheap (no rows transferred). If you keep a sampled
sweep for *discovery* (finding keys you didn't know about), label it as sampled
in the response and in the UI — a sampled number presented as exact is the same
bug wearing a different hat.

---

## 3. `Accept-Language` can 502 the whole response

Forcing a logon language gets you a gateway error, not a translated string, when
the text is not maintained in that language for **every row** in the result:

```python
headers = {"Accept-Language": "tr"}   # ✗ 502 on rows with no TR short text
```

One unmaintained row fails the whole response. Unless full translation is
confirmed, drop the header and take the communication user's default
(`sap-language=EN` on the destination). Then say so in the UI: the message text
is whatever language the job logged it in, and your i18n layer does **not**
translate service data. Document that boundary where the dictionary lives, or
someone will "fix" it by translating SAP messages.

---

## 4. Shared log tables: the module filter and the key padding

Cross-module log tables — one physical table, many producing modules —
carry two traps that both return **zero rows instead of an error**.

**The module filter is not optional.** The table holds other modules' rows. Omit
`Modul eq 'SD'` and another team's failures appear in your dashboard, attributed
to you.

**Key padding differs per system.** The same logical integration id was stored as
`'030'` in DEV and `'30'` in QA. A filter written against one system returns
zero rows in the other — not an error, not a 404, just nothing.

```python
def id_variants(v):
    n = int(v)
    return sorted({str(n), f"{n:02d}", f"{n:03d}"}, key=len)

expr = " or ".join(f"Entid eq '{v}'" for v in id_variants(eid))
filt = f"Modul eq 'SD' and ({expr})"
```

**The general rule this is an instance of:** when a count is zero, *measure why*
before assuming the data is empty. In a read-only monitor, "0" is a legitimate
answer, so a bug that produces "0" is invisible by construction. Make the UI able
to distinguish "no rows matched" from "the filter never matched anything in this
system" — e.g. show the unfiltered count next to the filtered one.

---

## 5. Dates exposed as strings need quoted literals

Provider-side, `Edm.Date` is a trap for ABAP `DATS` columns (see
`abap-cloud-rap-provider.md` — the `'00000000'` initial date is not a valid
`Edm.Date` and a single empty row 500s the whole response). The common fix is to
expose the column as `abap.char(8)`.

That fix moves to the consumer. The filter is now a **string comparison**:

```python
# Edm.Date column
f"Erdat ge {cutoff.isoformat()}"        # 2026-09-01, unquoted

# char(8) column
f"Cdate ge '{cutoff.strftime('%Y%m%d')}'"   # '20260901', QUOTED
```

Mixing them up gives a 400 that names a parse failure, which is at least loud.
The quiet version is worse: lexical comparison on `YYYYMMDD` happens to be
chronologically correct, so a half-migrated codebase works until someone changes
the format.

Carry a flag on the entity's descriptor (`date_is_string`) rather than deciding
at each call site.

---

## 6. Anchor the window to the data, not to today

"Last 7 days" is the obvious default and it is wrong against any system whose
feed has stopped — which is exactly the system you are monitoring.

A stale source returns an empty window, the dashboard shows zero errors, and zero
errors reads as *healthy*. The failure mode of a monitoring tool should never be
"looks fine".

Offer both and make the choice visible:

| Mode | Window | Use |
|---|---|---|
| `today` | `today - N … today` | source confirmed live |
| `latest` | `maxdate(data) - N … maxdate(data)` | default while onboarding |
| `all` | no date filter | investigation |

Whichever is active, show the actual date range on screen. "Last 7 days" over
data whose newest row is from March is a sentence that lies.

---

## 7. Cache with single-flight, and make the cache visible

Several panels on one screen will each ask for the same report. Without
coordination you get N identical pulls through the Cloud Connector tunnel.

- **Cache** per (entity, window) with a short TTL (minutes).
- **Single-flight**: concurrent callers for the same key wait on one in-flight
  request rather than starting their own.
- **Expose a refresh** that clears *every* layer. A refresh that clears the
  aggregate but not the per-entity cache re-aggregates stale rows and reports
  itself as fresh — the most confusing possible outcome.

---

## 8. Ask in bulk, and chunk the `$filter`

Looking up master-data existence (does this material/supplier exist?) one row at
a time means one tunnel round-trip per row — 5000 rows, 5000 round-trips.

Collect the distinct keys, ask in one filter — then chunk it, because `$filter`
is a URL query parameter and SAP's ICM returns **`414 Request-URI Too Long`**
well before you expect. 50 keys per request is safe and still does useful work
per trip.

```python
for i in range(0, len(keys), 50):
    expr = " or ".join(f"(ObjType eq '{t}' and ObjKey eq '{esc(k)}')"
                       for t, k in keys[i:i+50])
```

Escape single quotes (`'` → `''`) even when the keys come from SAP rather than a
user. One apostrophe in a material description breaks the whole chunk.

**One view beats two.** If you need existence for two object types, a `union all`
view with a discriminator column (`ObjType`) costs one transport, one `expose`,
and — the part that matters — **one** tunnel round-trip instead of two.

---

## 9. "Couldn't ask" is not "doesn't exist"

The rule that makes bulk existence checks safe, and the one most often skipped.

A failed lookup must produce a third state. Two states (`True`/`False`) force
every failure to become `False`, which renders as *"not defined in SAP — create
the master record"* — sending the operator to do work that doesn't exist.

```python
return {"available": reason is None,   # could we ask at all?
        "reason": reason,              # why not
        "found": found}                # only keys we actually resolved
```

Three consequences worth enforcing:

1. **Never cache a failure.** An outage must not become a permanent "doesn't
   exist" that survives the outage.
2. **Keys from a failed chunk stay out of the result** — absent, not `False`.
3. **The unknown state must be visible.** Put it in the response metadata and
   render a warning. A silent fallback means a half-finished setup can sit in
   production for months while operators dutifully check things that are fine.

---

## 10. Reconstruct history instead of storing it

A trend chart seems to need stored snapshots. Usually it doesn't.

If each business record carries a first-failure date and a resolution date, the
open set at any past date is derivable:

```python
def open_at(records, on):
    return [r for r in records
            if r.first_date and r.first_date <= on
            and (r.resolved_date is None or r.resolved_date > on)]
```

This works on day one, covers the period *before* you deployed, and needs no
scheduled job. Two limits — state both on the chart, don't bury them:

- Records older than your pull window aren't in the set. Past and present measure
  the **same population**, so the *slope* is right even though the absolute level
  is bounded by the window.
- If you convert currencies, past points use **today's** rate unless you store
  historical rates. Say so, or a currency swing reads as a change in the data.

Persist snapshots when the source starts aging out its own logs, when you shrink
the window, or when you need point-in-time rates — not before.

---

## 11. Never sum across currencies

Applies to totals, breakdowns, and projections alike. `1000 EUR + 1000 RON` must
never become `2000`.

- Show each currency separately; offer a converted total **alongside**, labelled.
- A currency with no available rate is **excluded** from the total and named in
  the response — never folded in at parity.
- In a grouped breakdown, a group with mixed currencies gets **no single amount**.
  A quantity total is still fine.

This is the one place where refusing to produce a number is the correct feature.

---

## 12. Degrade panels on the data, not on a per-source flag

Entities differ: some carry amounts, some only counts; some produce real error
rows, some only warnings. Drive the UI from what the descriptor declares:

- no amount field → hide money panels, say *why* in one line, keep counts
- no error rows by design → don't render an empty error table; an empty table
  reads as "all clear" and it is not

An empty state that can't be distinguished from a healthy state is a bug, not a
layout choice.
