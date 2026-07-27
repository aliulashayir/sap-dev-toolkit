# Advanced RAP / OData V4 topics

Read the section you need. These are less-common but high-cost-when-they-surprise
areas. Where exact names/shapes vary by service, the guidance is "recognize it in
`$metadata`, then confirm the specifics there" rather than assuming.

## Draft-enabled RAP entities

Many RAP business objects are **draft-enabled**, and this changes everything about
how you create/edit. Recognize it in `$metadata`:

- The entity's key includes a boolean `IsActiveEntity`. Every instance therefore
  exists in up to two versions: **active** (`IsActiveEntity=true`) and **draft**
  (`IsActiveEntity=false`). Your row URLs must carry this key part.
- `@Common.DraftRoot` (on the root entity) / `@Common.DraftNode` (on children), and
  a `DraftAdministrativeData` navigation property.
- Bound draft actions appear as `<Action>`s — commonly named (technical names vary)
  `Edit` / `Activate` / `Discard` / `Prepare` / `Resume`.

Typical lifecycle (confirm action names against the metadata):

1. **Create**: POST to the entity set creates a *draft* (`IsActiveEntity=false`),
   not an active record. It also takes a lock.
2. **Edit an existing active record**: call the `Edit` action on the active
   instance → produces a draft copy you then modify with PATCH against the draft
   key (`IsActiveEntity=false`).
3. **Modify**: PATCH the draft instance (the `IsActiveEntity=false` version).
4. **Validate without saving** (optional): call `Prepare` — runs determinations/
   validations and surfaces messages without activating.
5. **Save**: call the `Activate` action → the draft becomes the active record.
6. **Cancel**: call `Discard` → deletes the draft and releases the lock.

Consequences that bite if you treat it as non-draft:
- A plain POST "didn't save" — it made a draft; you forgot to `Activate`.
- A dangling lock — you created/edited a draft and neither activated nor discarded.
  Discard on cancel/navigation-away.
- Reading back: `$filter=IsActiveEntity eq true` for the persisted set;
  `SiblingEntity` navigation moves between a record's draft and active versions.
- Validation errors show up on `Prepare`/`Activate`, not on the PATCHes.

If the service is NOT draft-enabled (no `IsActiveEntity` key), ignore all of this —
POST/PATCH persist directly, as covered in `rap-write-semantics.md`.

## `$batch` — grouped and transactional writes

`POST <service-root>/$batch` bundles multiple operations in one HTTP call. OData V4
supports a JSON batch format (`Content-Type: application/json`, a `requests` array).

- **Changesets = atomicity.** Requests grouped in a changeset are all-or-nothing
  (transactional); the server rolls back the whole set on any failure. Requests
  outside a changeset (typically GETs) are not transactional.
- **Content-ID referencing**: within a changeset, later requests can reference an
  entity created by an earlier one (via `$<Content-ID>` in the URL) — the way to
  create a parent and its children atomically when deep insert isn't allowed.
- **Use it for**: reducing round-trips (fetch several unrelated things at once), or
  making a multi-entity write atomic (parent + children, or several sibling edits).
- **Cloud SDK**: the typed OData client has first-class batch support (build
  requests, wrap in `batch(...)`/changesets). With raw `executeHttpRequest`, POST
  the JSON batch payload to `/$batch` yourself.
- **Caution**: batch error handling is nested — a 200 on the batch envelope can
  still contain per-request failures in the response body. Inspect each sub-response,
  and reuse the same `extractODataError` idea one level deeper.

## `$expand` — depth, cost, restrictions

- `$expand=_Child` pulls a composition/association inline (one round-trip instead of
  N). This is how you fetch a header with its items.
- Trim it: `$expand=_Child($select=Field1,Field2)` — and you can nest,
  `$expand=_Child($expand=_GrandChild)`, but services often cap depth.
- Check `Capabilities.ExpandRestrictions` in the metadata: whether expand is allowed
  at all, which nav props are non-expandable, and any `MaxLevels`.
- Deep `$expand` can be slow/large; prefer `$select` inside it, and don't expand
  collections you won't render.

## Actions and functions

RAP exposes custom business operations as OData **actions** (side effects, POST) and
**functions** (side-effect-free, GET). This is how workflow-style buttons get wired.

- **Bound** (on an entity/collection) vs **unbound** (an `ActionImport`/
  `FunctionImport` on the container). Find them as `<Action>`/`<Function>` +
  `<ActionImport>`/`<FunctionImport>` in `$metadata`.
- **Invoke a bound action**: `POST /Entity/key.../ActionName` with the action's
  parameters in the JSON body. Bound to a collection: `POST /EntitySet/ActionName`.
- **Invoke a function**: `GET` with parameters (inline in the URL per the metadata).
- **This is the right home for things like an "approve"/"submit"/"post" button** —
  those are almost always actions on the backend, NOT something you emulate by
  PATCHing a status field yourself. Look for the action before hand-rolling a status
  write (see the "don't invent data" rule — writing a status code directly usually
  bypasses the workflow the action triggers).
- Draft interaction: on a draft-enabled BO, custom actions may need to run against
  the active instance (or the draft), and some are only valid in one state — the
  metadata's action annotations and the service behavior tell you which.

## Etag concurrency (cross-reference)

Covered in `rap-write-semantics.md` — services may require `If-Match` on
update/delete (412 otherwise). Draft flows and `$batch` both interact with ETags;
if you hit 412 inside a batch changeset, that's the cause.
