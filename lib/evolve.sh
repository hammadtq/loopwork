#!/usr/bin/env bash
# evolve.sh — Read evolution log and build context for the next iteration.
# Also appends new entries after each iteration.

set -euo pipefail

REPO_DIR="${1:?Usage: evolve.sh <repo-dir> <command> [args...]}"
COMMAND="${2:?Command required: context|log|recent}"
EVOLUTION_LOG="${REPO_DIR}/EVOLUTION_LOG.md"

# Initialize log if it doesn't exist
if [[ ! -f "$EVOLUTION_LOG" ]]; then
  cp "$(dirname "${BASH_SOURCE[0]}")/../templates/EVOLUTION_LOG.md" "$EVOLUTION_LOG"
fi

# ─── Get recent learnings as context for next iteration ──────────────────────
get_context() {
  local max_entries="${1:-5}"

  if [[ ! -s "$EVOLUTION_LOG" ]]; then
    echo "No evolution history yet."
    return 0
  fi

  echo "## Learnings from previous iterations"
  echo ""
  awk '/^### \[/ { count++ } count > '"$max_entries"' { exit } { print }' "$EVOLUTION_LOG" | \
    grep -A100 '^### \[' | head -100
}

# ─── Log an iteration result ────────────────────────────────────────────────
log_entry() {
  local item_number="${1:?Item number required}"
  local item_title="${2:?Item title required}"
  local result="${3:?Result required: SUCCESS|FAILURE|SCOPE_DRIFT|BLOCKED}"
  local error="${4:-none}"
  local fix="${5:-N/A}"
  local learning="${6:-}"
  local files_changed="${7:-}"

  local timestamp
  timestamp=$(date +%Y-%m-%d_%H:%M:%S)

  # Build entry in a temp file, then insert after "## Log" marker
  # This avoids fragile sed multiline append
  local tmpfile
  tmpfile=$(mktemp)

  # Write everything before and including "## Log" line
  awk '/^## Log/ { print; found=1; next } !found { print }' "$EVOLUTION_LOG" > "$tmpfile"

  # If "## Log" wasn't found, just cat the whole file
  if ! grep -q '^## Log' "$tmpfile"; then
    cat "$EVOLUTION_LOG" > "$tmpfile"
    echo "" >> "$tmpfile"
    echo "## Log" >> "$tmpfile"
  fi

  # Append the new entry
  cat >> "$tmpfile" <<EOF

### [${timestamp}] Item ${item_number}: ${item_title}
- **Attempt**: Automated iteration
- **Result**: ${result}
- **Error**: ${error}
- **Fix applied**: ${fix}
- **Learning**: ${learning}
- **Files changed**: ${files_changed}
EOF

  # Append everything after "## Log" from the original
  awk '/^## Log/ { found=1; next } found { print }' "$EVOLUTION_LOG" >> "$tmpfile"

  # Replace original
  mv "$tmpfile" "$EVOLUTION_LOG"

  echo "Logged: Item ${item_number} — ${result}"
}

# ─── Get recent failures for a specific item (for retry context) ────────────��
get_item_failures() {
  local item_number="${1:?Item number required}"

  awk "/^### .*Item ${item_number}:/,/^### \[/" "$EVOLUTION_LOG" | \
    grep -B1 -A5 'FAILURE\|SCOPE_DRIFT' | head -30
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
case "$COMMAND" in
  context)  get_context "${3:-5}" ;;
  log)      log_entry "${3:?}" "${4:?}" "${5:?}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" ;;
  recent)   get_item_failures "${3:?}" ;;
  *)        echo "Usage: evolve.sh <repo-dir> <context|log|recent> [args]" >&2; exit 1 ;;
esac
