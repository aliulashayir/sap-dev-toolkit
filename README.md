# SAP OData / RAP / Cloud SDK integration — Claude Code plugin

A Claude Code plugin that packages a battle-tested **skill** for integrating a
frontend/BFF with **SAP OData V4** services built on **RAP** (ABAP RESTful
Application Programming Model, typically S/4HANA Public Cloud) via the **SAP
Cloud SDK for JavaScript**, and binding the result into a **UI5/Fiori** frontend.

It front-loads the gotchas that otherwise cost a debugging session each — reading
`$metadata`, RAP write semantics, the Cloud SDK error/pagination/CSRF details, UI
binding at the type boundary, and a symptom → cause → fix table for the common
400/404/412 failures.

## What's inside

```
plugins/sap-odata-rap-integration/
└── skills/sap-odata-rap-integration/
    ├── SKILL.md                      # the playbook (7 rules + error→fix table + workflow)
    └── references/
        ├── odata-metadata.md         # reading $metadata / annotations
        ├── rap-write-semantics.md    # POST/PATCH/DELETE, composite keys, semantic pairing
        ├── cloud-sdk-bff.md          # Cloud SDK, error extraction, pagination, CSRF, auth
        ├── ui-binding.md             # type boundary, value-helps, validation
        └── advanced-topics.md        # drafts, $batch, $expand, actions/functions
```

The skill triggers automatically when Claude is working on SAP OData/RAP/Cloud SDK
integration — or invoke it explicitly with `/sap-odata-rap-integration`.

## Install

```
/plugin marketplace add CHANGE-ME/sap-odata-rap-integration-plugin
/plugin install sap-odata-rap-integration@sap-odata-rap
```

The first line registers this repo as a marketplace (`CHANGE-ME` → your GitHub
`owner/repo`); the second installs the plugin from it. Update later with
`/plugin marketplace update sap-odata-rap`.

## Adding hooks / commands / agents later

This plugin currently ships only a skill. To extend it, drop components into the
plugin directory (`plugins/sap-odata-rap-integration/`) — Claude Code
auto-discovers them:

- `hooks/hooks.json` — event hooks (PreToolUse, PostToolUse, etc.)
- `commands/*.md` — slash commands
- `agents/*.md` — subagents

See the [Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference).

## License

MIT — see [LICENSE](./LICENSE). Change if your team needs a different one.
