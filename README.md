# sap-dev-toolkit — SAP OData / RAP / Cloud SDK toolkit for Claude Code

A Claude Code plugin for building against **SAP OData V4** services built on **RAP**
(ABAP RESTful Application Programming Model, typically S/4HANA Public Cloud) via the
**SAP Cloud SDK for JavaScript**, and binding the result into a **UI5/Fiori** frontend.

It bundles a battle-tested skill, slash commands, specialized agents, and an advisory
hook — front-loading the gotchas that otherwise cost a debugging session each: reading
`$metadata`, RAP write semantics, the Cloud SDK error/pagination/CSRF details, UI binding
at the type boundary, and a symptom → cause → fix map for the common 400/404/412 failures.

## What's inside

```text
plugins/sap-dev-toolkit/
├── skills/sap-odata-rap-integration/
│   ├── SKILL.md                      # the playbook (7 rules + error→fix table + workflow)
│   └── references/
│       ├── odata-metadata.md         # reading $metadata / annotations
│       ├── rap-write-semantics.md    # POST/PATCH/DELETE, composite keys, semantic pairing
│       ├── cloud-sdk-bff.md          # Cloud SDK, error extraction, pagination, CSRF, auth
│       ├── ui-binding.md             # type boundary, value-helps, validation
│       └── advanced-topics.md        # drafts, $batch, $expand, actions/functions
├── commands/                         # slash commands (see below)
├── agents/                           # subagents (see below)
├── hooks/hooks.json                  # PostToolUse advisory hook
└── scripts/check-odata-error-handling.sh
```

### Skill

`sap-odata-rap-integration` triggers automatically when Claude is working on SAP
OData/RAP/Cloud SDK integration — or invoke it explicitly with `/sap-odata-rap-integration`.

### Commands

- **`/odata-metadata-map [path|url]`** — parse a `$metadata` (EDMX) into a field map + integration watch-list.
- **`/odata-debug [error]`** — walk the error→cause→fix map for an SAP OData/RAP/Cloud SDK failure (surfaces the real error first).
- **`/odata-value-help [EntitySet]`** — scaffold a value-help end to end (paginated BFF route + hook + filterable ComboBox).

### Agents

- **`odata-metadata-analyst`** — read-only; ingests a `$metadata` doc and returns a structured field map + watch-list. Use before wiring a new entity.
- **`odata-integration-reviewer`** — reviews integration code against the known footguns (swallowed errors, type-boundary bugs, keys in PATCH bodies, unpaired unit/currency, unfollowed pagination, mutable keys). Use before committing.

### Hook

A **PostToolUse** hook (`Write|Edit`) that emits a **non-blocking** advisory when an edited
file makes raw SAP OData / Cloud SDK calls but appears to surface `err.message` (the useless
"Request failed with status code 400") without extracting the real OData error. It fires only
on relevant files and no-ops silently otherwise (and if `jq` isn't installed). Being
`command`-type, it runs code, so under project scope it loads only after the trust prompt.

## Install

```text
/plugin marketplace add aliulashayir/sap-dev-toolkit
/plugin install sap-dev-toolkit@sap-dev-tools
```

The first line registers this repo as a marketplace (`CHANGE-ME` → your GitHub
`owner/repo`); the second installs the plugin from the `sap-dev-tools` catalog. Update
later with `/plugin marketplace update sap-dev-tools`.

## Extending it

Components live under `plugins/sap-dev-toolkit/` and are auto-discovered by Claude Code —
add more `commands/*.md`, `agents/*.md`, another skill under `skills/`, or extra events in
`hooks/hooks.json`. See the
[Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference).

## License

MIT — see [LICENSE](./LICENSE).
