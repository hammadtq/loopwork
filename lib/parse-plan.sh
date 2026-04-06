#!/usr/bin/env bash
# parse-plan.sh — Extract items and metadata from MASTER_PLAN.md
# Called by run.sh to determine what to work on next.

set -euo pipefail

PLAN_FILE="${1:?Usage: parse-plan.sh <path-to-MASTER_PLAN.md>}"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "ERROR: Plan file not found: $PLAN_FILE" >&2
  exit 1
fi

# ─── Portable sed -i ─────────────────────────────────────────────────────────
sedi() {
  # Works on both macOS (BSD sed) and Linux (GNU sed)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ─── Get next item to work on ───────────────────────────────────────────────
# Priority: [>] (explicit next) > first [ ] (todo in order)
get_next_item() {
  local plan="$PLAN_FILE"

  # First, look for [>] (do next) marker
  local priority_match
  priority_match=$(grep -n '^### \[>\]' "$plan" | head -1 || true)

  if [[ -n "$priority_match" ]]; then
    local line_num="${priority_match%%:*}"
    extract_item "$plan" "$line_num"
    return 0
  fi

  # Otherwise, find first [ ] (todo) item
  local todo_match
  todo_match=$(grep -n '^### \[ \]' "$plan" | head -1 || true)

  if [[ -n "$todo_match" ]]; then
    local line_num="${todo_match%%:*}"
    extract_item "$plan" "$line_num"
    return 0
  fi

  # No items left
  echo "NO_ITEMS_LEFT"
  return 0
}

# ─── Extract a single item's details from a line number ──────────────────────
extract_item() {
  local plan="$1"
  local start_line="$2"
  local total_lines
  total_lines=$(wc -l < "$plan")

  # Find the end of this item (next ### header or end of file)
  local end_line
  end_line=$(awk -v start="$((start_line + 1))" 'NR > start && /^### \[/ { print NR; exit }' "$plan")
  end_line="${end_line:-$((total_lines + 1))}"

  # Extract the item block
  local block
  block=$(sed -n "${start_line},$((end_line - 1))p" "$plan")

  # Parse fields — match multi-char status markers like [wip], [blocked], [skip]
  local title
  title=$(echo "$block" | head -1 | sed 's/^### \[[^]]*\] [0-9]*\. //')

  # Extract item number: match "N." right after the status marker
  local item_number
  item_number=$(echo "$block" | head -1 | sed 's/^### \[[^]]*\] //' | grep -o '^[0-9]*' || echo "0")

  local description
  description=$(echo "$block" | grep '^\- \*\*Description\*\*' | sed 's/^- \*\*Description\*\*: //')

  local scope
  scope=$(echo "$block" | grep '^\- \*\*Scope\*\*' | sed 's/^- \*\*Scope\*\*: //' | tr -d '`')

  local forbidden
  forbidden=$(echo "$block" | grep '^\- \*\*Forbidden\*\*' | sed 's/^- \*\*Forbidden\*\*: //' | tr -d '`')

  # Extract success criteria (lines starting with "  - [ ]")
  local criteria
  criteria=$(echo "$block" | grep '^\s*- \[ \]' | sed 's/^\s*- \[ \] //' || echo "")

  local dependencies
  dependencies=$(echo "$block" | grep '^\- \*\*Dependencies\*\*' | sed 's/^- \*\*Dependencies\*\*: //' || echo "None")

  # Check for milestone grouping
  local milestone
  milestone=$(sed -n "$((start_line - 3)),$((start_line - 1))p" "$plan" | grep '<!-- milestone:' | sed 's/.*<!-- milestone: \(.*\) -->.*/\1/' || echo "")

  # Detect item type: "review" if description contains a PR ref (owner/repo#N or #N)
  local item_type="build"
  local pr_ref=""
  if echo "$description" | grep -qE '(^|[[:space:]])(review|Review):?[[:space:]]'; then
    item_type="review"
  fi
  # Extract PR ref from description: owner/repo#N or just #N
  pr_ref=$(echo "$description" | grep -oE '[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' | head -1 || true)
  if [[ -z "$pr_ref" ]]; then
    pr_ref=$(echo "$description" | grep -oE '#[0-9]+' | head -1 || true)
  fi
  if [[ -n "$pr_ref" ]]; then
    item_type="review"
  fi

  # Output as safely quoted key=value pairs using printf %q to prevent injection
  printf 'ITEM_NUMBER=%q\n' "$item_number"
  printf 'ITEM_TITLE=%q\n' "$title"
  printf 'ITEM_LINE=%q\n' "$start_line"
  printf 'ITEM_DESCRIPTION=%q\n' "$description"
  printf 'ITEM_SCOPE=%q\n' "$scope"
  printf 'ITEM_FORBIDDEN=%q\n' "$forbidden"
  printf 'ITEM_CRITERIA=%q\n' "$criteria"
  printf 'ITEM_DEPENDENCIES=%q\n' "$dependencies"
  printf 'ITEM_MILESTONE=%q\n' "$milestone"
  printf 'ITEM_TYPE=%q\n' "$item_type"
  printf 'ITEM_PR_REF=%q\n' "$pr_ref"
}

# ─── Mark an item with a new status ──────────────────────────────────────────
mark_item() {
  local plan="$1"
  local item_number="$2"
  local new_status="$3"  # x, skip, blocked, wip, " " (space = reset to todo), >

  # Find the line with this item number — match any status marker including multi-char
  # Use word boundary (trailing dot+space) to avoid item 1 matching item 10
  local line
  line=$(grep -n "^### \[[^]]*\] ${item_number}\. " "$plan" | head -1 || true)

  if [[ -z "$line" ]]; then
    echo "ERROR: Item $item_number not found in plan" >&2
    return 1
  fi

  local line_num="${line%%:*}"

  # Replace the status marker on that line (handles multi-char markers)
  sedi "${line_num}s/^### \[[^]]*\]/### [${new_status}]/" "$plan"
  echo "Marked item $item_number as [${new_status}]"
}

# ─── Count items by status ───────────────────────────────────────────────────
count_items() {
  local plan="$PLAN_FILE"
  local total done todo wip blocked skipped priority

  total=$(grep -c '^### \[' "$plan" || echo 0)
  done=$(grep -c '^### \[x\]' "$plan" || echo 0)
  todo=$(grep -c '^### \[ \]' "$plan" || echo 0)
  wip=$(grep -c '^### \[wip\]' "$plan" || echo 0)
  blocked=$(grep -c '^### \[blocked\]' "$plan" || echo 0)
  skipped=$(grep -c '^### \[skip\]' "$plan" || echo 0)
  priority=$(grep -c '^### \[>\]' "$plan" || echo 0)

  echo "TOTAL=${total} DONE=${done} TODO=${todo} WIP=${wip} BLOCKED=${blocked} SKIPPED=${skipped} PRIORITY=${priority}"
}

# ─── Get vision section ──────────────────────────────────────────────────────
get_vision() {
  local plan="$PLAN_FILE"
  awk '/^## Vision/,/^## [A-Z]/' "$plan" | sed '$d' | tail -n +2 | grep -v '<!--' || true
}

# ─── Get guardrails section ──────────────────────────────────────────────────
get_guardrails() {
  local plan="$PLAN_FILE"
  awk '/^## Global Guardrails/,/^## [A-Z]/' "$plan" | sed '$d' | tail -n +2 | grep -v '<!--' || true
}

# ─── Get evolution rules ─────────────────────────────────────────────────────
get_evolution_rules() {
  local plan="$PLAN_FILE"
  awk '/^## Evolution Rules/,/^## [A-Z]/' "$plan" | sed '$d' | tail -n +2 | grep -v '<!--' || true
}

# ─── CLI interface ───────────────────────────────────────────────────────────
case "${2:-next}" in
  next)      get_next_item ;;
  mark)      mark_item "$PLAN_FILE" "${3:?item number}" "${4:?status}" ;;
  count)     count_items ;;
  vision)    get_vision ;;
  guardrails) get_guardrails ;;
  rules)     get_evolution_rules ;;
  *)         echo "Usage: parse-plan.sh <plan-file> [next|mark|count|vision|guardrails|rules]" >&2; exit 1 ;;
esac
