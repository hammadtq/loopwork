#!/usr/bin/env bash
# scope-guard.sh — Claude Code PreToolUse hook.
# Blocks file writes outside the current item's allowed scope.
#
# Configure in .claude/settings.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Edit|Write",
#       "hooks": [{
#         "type": "command",
#         "command": "/path/to/scope-guard.sh"
#       }]
#     }]
#   }
# }
#
# Reads .workflow/current_scope.json (written by run.sh before each Claude invocation).

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool name and file path
TOOL_NAME=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('tool_name', ''))
" <<< "$INPUT" 2>/dev/null || echo "")

FILE_PATH=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
inp = data.get('tool_input', {})
print(inp.get('file_path', inp.get('path', '')))
" <<< "$INPUT" 2>/dev/null || echo "")

# Only check Edit and Write tools
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Look for scope file (written by run.sh via write_scope_file)
SCOPE_FILE=".workflow/current_scope.json"
if [[ ! -f "$SCOPE_FILE" ]]; then
  exit 0  # No scope restrictions active
fi

# Read scopes safely via Python (no string interpolation)
read -r ALLOWED FORBIDDEN < <(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('allowed', ''), data.get('forbidden', ''))
" "$SCOPE_FILE" 2>/dev/null || echo "")

# Make file path relative to repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REL_PATH="${FILE_PATH#$REPO_ROOT/}"

# Check forbidden first
if [[ -n "$FORBIDDEN" ]]; then
  IFS=',' read -ra patterns <<< "$FORBIDDEN"
  for pattern in "${patterns[@]}"; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"  # trim leading whitespace
    pattern="${pattern%"${pattern##*[![:space:]]}"}"  # trim trailing whitespace
    [[ -z "$pattern" ]] && continue
    pattern="${pattern%/}"
    if [[ "$REL_PATH" == "$pattern" || "$REL_PATH" == "${pattern}/"* ]]; then
      cat <<EOF
{
  "permissionDecision": "deny",
  "additionalContext": "SCOPE GUARD: Blocked write to '${REL_PATH}' — this file/directory is FORBIDDEN for the current item. Allowed scope: ${ALLOWED}. Forbidden: ${FORBIDDEN}."
}
EOF
      exit 0
    fi
  done
fi

# Check allowed scope
if [[ -n "$ALLOWED" && "$ALLOWED" != "any" ]]; then
  is_allowed=false
  IFS=',' read -ra patterns <<< "$ALLOWED"
  for pattern in "${patterns[@]}"; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -z "$pattern" ]] && continue
    pattern="${pattern%/}"
    if [[ "$REL_PATH" == "$pattern" || "$REL_PATH" == "${pattern}/"* ]]; then
      is_allowed=true
      break
    fi
  done

  if [[ "$is_allowed" == "false" ]]; then
    cat <<EOF
{
  "permissionDecision": "deny",
  "additionalContext": "SCOPE GUARD: Blocked write to '${REL_PATH}' — outside allowed scope. Allowed: ${ALLOWED}. If you need to modify this file, STOP and explain why."
}
EOF
    exit 0
  fi
fi

# Allow the write
exit 0
