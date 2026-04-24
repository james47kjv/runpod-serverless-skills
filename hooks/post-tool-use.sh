#!/usr/bin/env bash
# runpod-serverless plugin — PostToolUse hook
#
# Reads the Bash tool's stdin (Claude Code passes {tool_input, tool_response} as JSON on
# stdin for PostToolUse hooks). If the bash command contained `saveEndpoint`, emit a
# drift-audit reminder to stderr. Read-only: never deploys, never mutates.
#
# To disable: delete this file OR remove the PostToolUse entry from hooks.json.

# Read tool event payload; keep it short. Fall back to env-passed command string if stdin
# isn't a JSON payload (harness version differences).
payload="$(cat 2>/dev/null || true)"
cmd=""
if command -v python3 >/dev/null 2>&1 && [[ -n "$payload" ]]; then
    cmd="$(printf '%s' "$payload" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(str(d.get("tool_input", {}).get("command", "")))
except Exception:
    print("")' 2>/dev/null)"
fi

# If the tool payload looks like a saveEndpoint mutation, drop the reminder.
case "$cmd" in
    *saveEndpoint*)
        printf '[runpod-serverless post-tool-use] saveEndpoint mutation detected. ' 1>&2
        printf 'Run the drift audit before claiming the deploy is green:\n' 1>&2
        printf '  python scripts/serverless/audit_digest.py --endpoint-id <ID> --manifest release/<env>-deploy-*.json\n' 1>&2
        ;;
esac

# Hook must exit 0 so we never block the parent tool call.
exit 0
