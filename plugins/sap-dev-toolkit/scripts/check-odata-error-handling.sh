#!/usr/bin/env bash
# PostToolUse (Write|Edit) advisory for the sap-odata-rap-integration plugin.
#
# Fires ONLY when the just-edited file both (a) makes raw SAP OData / Cloud SDK
# calls and (b) looks like it surfaces the useless axios `err.message` while no
# `extractODataError`-style helper is present. Emits non-blocking context so
# Claude is nudged to surface the REAL OData error (the #1 debugging rule).
#
# Non-blocking by design: always exits 0. Degrades to silent no-op if `jq` is
# missing or the input isn't a code file, so it can never break a session.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

[ -n "$file" ] && [ -f "$file" ] || exit 0
case "$file" in
  *.ts | *.tsx | *.js | *.mjs | *.cjs) ;;
  *) exit 0 ;;
esac

# Only relevant to files that actually make OData / Cloud SDK HTTP calls.
grep -qiE 'executeHttpRequest|\$metadata|@sap-cloud-sdk' "$file" || exit 0

# Swallowed-error smell: returns the axios .message, and no OData-error extractor in sight.
if grep -qE '\bError\)\.message|\berr\.message|\be\.message' "$file" \
  && ! grep -q 'extractODataError' "$file"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "[sap-odata-rap-integration] This file makes SAP OData / Cloud SDK calls but a catch appears to surface `err.message` — that is the useless \"Request failed with status code 400\". Extract the real OData error from the response body instead: err.response?.data?.error?.message (also try err.cause?.response?.data). See the plugin skill'"'"'s references/cloud-sdk-bff.md."
    }
  }'
fi

exit 0
