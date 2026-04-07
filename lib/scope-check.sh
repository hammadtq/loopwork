#!/usr/bin/env bash
# scope-check.sh — Verify that changes are within the allowed scope for an item.
# Compares git diff against the item's allowed/forbidden directories.

set -euo pipefail

REPO_DIR="${1:?Usage: scope-check.sh <repo-dir> <allowed-scope> <forbidden-scope> [base-branch]}"
ALLOWED_SCOPE="${2}"   # Comma-separated dirs: "src/api/, src/models/"
FORBIDDEN_SCOPE="${3}" # Comma-separated dirs: ".env, src/auth/"
BASE_BRANCH="${4:-main}"

# ─── Get list of changed files ──────────────────────────────────────────────
get_changed_files() {
  cd "$REPO_DIR"
  # Uncommitted changes + committed-but-not-on-base
  {
    git diff --name-only HEAD 2>/dev/null || true
    git diff --name-only --cached 2>/dev/null || true
    git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true
  } | sort -u
}

# ─── Check if a file is within allowed scope ────────────────────────────────
# A file matches a pattern when:
#   - file == pattern (exact file match), OR
#   - file is inside pattern as a directory (boundary on '/')
# This prevents scope "src/api" from accidentally matching "src/apiary".
file_in_scope() {
  local file="$1"
  local scope="$2"

  # If scope is empty or "any", everything is allowed
  if [[ -z "$scope" || "$scope" == "any" ]]; then
    return 0
  fi

  IFS=',' read -ra patterns <<< "$scope"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)  # trim whitespace
    [[ -z "$pattern" ]] && continue
    # Normalize: drop a trailing slash so "src/api/" and "src/api" behave the same
    pattern="${pattern%/}"

    if [[ "$file" == "$pattern" || "$file" == "${pattern}/"* ]]; then
      return 0
    fi
  done

  return 1
}

# ─── Check if a file is in forbidden zone ────────────────────────────────────
file_is_forbidden() {
  local file="$1"
  local forbidden="$2"

  [[ -z "$forbidden" ]] && return 1

  IFS=',' read -ra patterns <<< "$forbidden"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    [[ -z "$pattern" ]] && continue
    pattern="${pattern%/}"

    # Exact file match OR directory containment with '/' boundary.
    if [[ "$file" == "$pattern" || "$file" == "${pattern}/"* ]]; then
      return 0
    fi
  done

  return 1
}

# ─── Main check ─────────────────────────────────────────────────────────────
main() {
  local changed_files
  changed_files=$(get_changed_files)

  if [[ -z "$changed_files" ]]; then
    echo '{"status":"clean","violations":[],"file_count":0}'
    return 0
  fi

  local violations=()
  local file_count=0
  local ok_count=0

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    file_count=$((file_count + 1))

    # Check forbidden first (takes priority)
    if file_is_forbidden "$file" "$FORBIDDEN_SCOPE"; then
      violations+=("{\"file\":\"$file\",\"reason\":\"forbidden\"}")
      continue
    fi

    # Check allowed scope
    if ! file_in_scope "$file" "$ALLOWED_SCOPE"; then
      violations+=("{\"file\":\"$file\",\"reason\":\"out_of_scope\"}")
      continue
    fi

    ok_count=$((ok_count + 1))
  done <<< "$changed_files"

  local violation_count=${#violations[@]}

  if [[ $violation_count -eq 0 ]]; then
    echo "{\"status\":\"pass\",\"violations\":[],\"file_count\":$file_count}"
    return 0
  else
    local violations_json
    violations_json=$(printf '%s,' "${violations[@]}")
    violations_json="[${violations_json%,}]"
    echo "{\"status\":\"drift\",\"violations\":$violations_json,\"file_count\":$file_count,\"ok_count\":$ok_count}"
    return 1
  fi
}

main
