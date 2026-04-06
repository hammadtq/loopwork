#!/usr/bin/env bash
# run.sh — Ralph loop for autonomous workflow automation.
#
# Usage:
#   ./run.sh <repo-dir>              # Interactive mode (you chat, loop orchestrates)
#   ./run.sh <repo-dir> --auto       # Headless mode (AFK, loop runs autonomously)
#   ./run.sh <repo-dir> --status     # Show current plan status
#
# Environment variables (optional):
#   WORKFLOW_MAX_RETRIES   — max consecutive failures before stopping (default: 3)
#   WORKFLOW_MAX_TURNS     — max Claude turns per item (default: 50)
#   WORKFLOW_TIMEOUT       — wall-clock timeout per item in seconds (default: 600)
#   WORKFLOW_BASE_BRANCH   — base branch (default: main)
#   WORKFLOW_PAUSE         — seconds between iterations in auto mode (default: 5)
#
# Mid-flight steering:
#   - Edit MASTER_PLAN.md directly (add/remove/reorder items)
#   - Drop a STEER.md in the repo root for one-shot corrections
#   - Mark items [>] to prioritize, [skip] to skip, [blocked] to defer

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

REPO_DIR="${1:?Usage: run.sh <repo-dir> [--auto|--status]}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"  # Resolve to absolute path
MODE="${2:---interactive}"
BASE_BRANCH="${WORKFLOW_BASE_BRANCH:-${3:-main}}"

PLAN_FILE="${REPO_DIR}/MASTER_PLAN.md"
WORKFLOW_DIR="${REPO_DIR}/.workflow"
MAX_RETRIES="${WORKFLOW_MAX_RETRIES:-3}"
MAX_TURNS="${WORKFLOW_MAX_TURNS:-50}"
TIMEOUT="${WORKFLOW_TIMEOUT:-600}"
PAUSE_BETWEEN_ITEMS="${WORKFLOW_PAUSE:-5}"

# Track background PIDs for cleanup
BG_PIDS=()

mkdir -p "$WORKFLOW_DIR"

# ─── Cleanup on exit ────────────────────────────────────────────────────────
cleanup() {
  for pid in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# ─── Portable timeout (macOS lacks coreutils timeout) ────────────────────────
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    # Fallback: run in background, kill after timeout
    "$@" &
    local pid=$!
    (sleep "$secs" && kill "$pid" 2>/dev/null) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local ret=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return $ret
  fi
}

# ─── Preflight checks ───────────────────────────────────────────────────────
preflight() {
  local errors=0

  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "ERROR: No MASTER_PLAN.md found in $REPO_DIR" >&2
    echo "  Copy MASTER_PLAN_TEMPLATE.md to your repo as MASTER_PLAN.md and fill it in." >&2
    errors=1
  fi

  if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found. Install from https://claude.ai/code" >&2
    errors=1
  fi

  if ! command -v git &>/dev/null; then
    echo "ERROR: git not found" >&2
    errors=1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found (required for JSON parsing)" >&2
    errors=1
  fi

  if ! command -v gh &>/dev/null; then
    echo "WARNING: gh CLI not found — PR creation will be skipped" >&2
  fi

  if ! command -v codex &>/dev/null; then
    echo "WARNING: codex CLI not found — Codex reviews will be skipped" >&2
  fi

  if [[ $errors -gt 0 ]]; then
    exit 1
  fi
}

# ─── Show status ─────────────────────────────────────────────────────────────
show_status() {
  echo ""
  echo "━━━ WORKFLOW STATUS ━━━"
  bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" count
  echo ""
  echo "Active worktrees:"
  bash "${LIB_DIR}/worktree.sh" "$REPO_DIR" list 2>/dev/null || echo "  (none)"
  echo ""
  echo "Next item:"
  bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" next | head -3
  echo "━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Build the prompt for Claude Code ────────────────────────────────────────
build_prompt() {
  local item_number="$1"
  local item_title="$2"
  local item_description="$3"
  local item_scope="$4"
  local item_forbidden="$5"
  local item_criteria="$6"
  local steer_content="$7"
  local evolution_context="$8"

  cat <<PROMPT
You are an autonomous coding agent working on a specific item from a master plan.

## Your task
**Item #${item_number}: ${item_title}**
${item_description}

## Scope constraints — CRITICAL
You may ONLY modify files in these directories: ${item_scope}
You must NEVER modify files in: ${item_forbidden}
If you need to change a file outside your scope, STOP and explain why.

## Success criteria
When you're done, ALL of these must be true:
${item_criteria}

## Rules
- Implement ONLY what's described above. No extra features, no "improvements."
- Follow existing code patterns in the repo.
- Write tests if the success criteria require them.
- Commit your changes with a clear message: "item-${item_number}: ${item_title}"
- If you're unsure about an architectural decision, STOP and say so.
- If you encounter a dependency that should be done first, STOP and say so.

## Context from previous iterations
${evolution_context}

${steer_content:+## Course correction from human
$steer_content}

Begin. Work through this systematically and commit when done.
PROMPT
}

# ─── Write scope file for the hook ──────────────────────────────────────────
write_scope_file() {
  local worktree_path="$1"
  local allowed="$2"
  local forbidden="$3"

  mkdir -p "${worktree_path}/.workflow"
  python3 -c "
import json, sys
json.dump({'allowed': sys.argv[1], 'forbidden': sys.argv[2]}, open(sys.argv[3], 'w'))
" "$allowed" "$forbidden" "${worktree_path}/.workflow/current_scope.json"
}

# ─── Parse item fields safely (no eval) ─────────────────────────────────────
# Reads printf %q-quoted key=value lines and sets variables via eval
parse_item_fields() {
  local input="$1"
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    # Values are already printf %q quoted, so eval is safe
    eval "$key=$value"
  done <<< "$input"
}

# ─── Run a single iteration (returns status via file, not subshell) ──────────
run_iteration() {
  local auto_mode="$1"
  local status_file="$2"

  # Check for steering input
  local steer_output
  steer_output=$(bash "${LIB_DIR}/steer.sh" "$REPO_DIR")
  local steer_content=""
  if [[ "$steer_output" == STEER_FOUND* ]]; then
    steer_content=$(echo "$steer_output" | tail -n +3)
    echo "  Steering input detected — applying to this iteration"
  fi

  # Get next item
  local next_item
  next_item=$(bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" next)

  if [[ "$next_item" == "NO_ITEMS_LEFT" ]]; then
    echo "ALL_DONE" > "$status_file"
    return 0
  fi

  # Parse item fields safely — values are printf %q escaped by parse-plan.sh
  parse_item_fields "$next_item"

  # Use the parsed ITEM_* variables
  local item_number="${ITEM_NUMBER:-0}"
  local item_title="${ITEM_TITLE:-untitled}"
  local item_description="${ITEM_DESCRIPTION:-}"
  local item_scope="${ITEM_SCOPE:-}"
  local item_forbidden="${ITEM_FORBIDDEN:-}"
  local item_criteria="${ITEM_CRITERIA:-}"
  local item_dependencies="${ITEM_DEPENDENCIES:-}"
  local item_type="${ITEM_TYPE:-build}"
  local item_pr_ref="${ITEM_PR_REF:-}"

  echo ""
  echo "┌─────────────────────────────────────────────────┐"
  echo "│  Item #${item_number}: ${item_title}"
  echo "│  Type: ${item_type}${item_pr_ref:+ (${item_pr_ref})}"
  echo "│  Scope: ${item_scope}"
  echo "└─────────────────────────────────────────────────┘"

  # ─── REVIEW items: delegate to review-fix loop ─────────────────────────
  if [[ "$item_type" == "review" && -n "$item_pr_ref" ]]; then
    bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "wip"

    echo "  Running review-fix loop for $item_pr_ref..."
    local review_workdir="${WORKFLOW_DIR}/review-${item_number}"
    mkdir -p "$review_workdir"

    if bash "${LIB_DIR}/review-fix.sh" "$item_pr_ref" "$review_workdir" 5; then
      bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "x"
      bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "SUCCESS" \
        "none" "N/A" "Review-fix loop completed for $item_pr_ref" ""
      echo "SUCCESS" > "$status_file"
    else
      bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "blocked"
      bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "FAILURE" \
        "Review-fix loop could not resolve all issues" "N/A" \
        "PR $item_pr_ref still has issues after max iterations" ""
      echo "FAILURE" > "$status_file"
    fi
    return 0
  fi

  # Check for scope overlap with active worktrees
  local overlap
  overlap=$(bash "${LIB_DIR}/worktree.sh" "$REPO_DIR" overlap "$item_scope" "$PLAN_FILE" 2>/dev/null || true)
  if [[ "$overlap" == OVERLAP* ]]; then
    echo "  WARNING: Scope overlaps with active worktree: $overlap"
    echo "  Serializing — waiting for overlapping item to complete."
    bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "blocked"
    echo "BLOCKED" > "$status_file"
    return 0
  fi

  # Mark as WIP
  bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "wip"

  # Get evolution context
  local evolution_context
  evolution_context=$(bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" context 5 2>/dev/null || echo "No previous history.")

  local item_failures
  item_failures=$(bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" recent "$item_number" 2>/dev/null || echo "")
  if [[ -n "$item_failures" ]]; then
    evolution_context="${evolution_context}

## Previous failures on this item
${item_failures}"
  fi

  # Build prompt
  local prompt
  prompt=$(build_prompt "$item_number" "$item_title" "$item_description" \
    "$item_scope" "$item_forbidden" "$item_criteria" \
    "$steer_content" "$evolution_context")

  # Create worktree for this item
  local worktree_path
  worktree_path=$(bash "${LIB_DIR}/worktree.sh" "$REPO_DIR" create "$item_number" "$BASE_BRANCH")
  echo "  Worktree: $worktree_path"

  # Write scope file for the hook
  write_scope_file "$worktree_path" "$item_scope" "$item_forbidden"

  # Run Claude Code with wall-clock timeout
  local claude_exit=0
  if [[ "$auto_mode" == "--auto" ]]; then
    echo "  Running Claude Code (headless, timeout ${TIMEOUT}s)..."
    pushd "$worktree_path" > /dev/null
    run_with_timeout "$TIMEOUT" claude -p "$prompt" \
      --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
      --max-turns "$MAX_TURNS" \
      --output-format text > "${WORKFLOW_DIR}/output_item_${item_number}.txt" 2>&1 || claude_exit=$?
    popd > /dev/null

    if [[ $claude_exit -eq 124 ]]; then
      echo "  TIMEOUT: Claude Code exceeded ${TIMEOUT}s wall-clock limit"
      bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "FAILURE" \
        "Timed out after ${TIMEOUT}s" "N/A" "Item too large or agent got stuck — consider splitting" ""
      bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "blocked"
      echo "FAILURE" > "$status_file"
      return 0
    fi
  else
    echo "  Starting Claude Code (interactive)..."
    echo "  Prompt saved to: ${WORKFLOW_DIR}/prompt_item_${item_number}.txt"
    echo "$prompt" > "${WORKFLOW_DIR}/prompt_item_${item_number}.txt"
    echo ""
    # Interactive mode: run claude directly (not in subshell) so stdin is the terminal
    pushd "$worktree_path" > /dev/null
    claude --resume || claude_exit=$?
    # Feed the prompt on first run by writing it to a file the user can reference
    popd > /dev/null
  fi

  # ─── Post-iteration checks ────────────────────────────────────────────
  pushd "$worktree_path" > /dev/null

  # Stage everything first so scope check can see new files
  git add -A 2>/dev/null || true

  # Check scope
  local scope_result
  scope_result=$(bash "${LIB_DIR}/scope-check.sh" "$worktree_path" "$item_scope" "$item_forbidden" "$BASE_BRANCH" 2>/dev/null || true)

  local scope_status
  scope_status=$(echo "$scope_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")

  if [[ "$scope_status" == "drift" ]]; then
    echo "  SCOPE DRIFT DETECTED!"
    echo "  $scope_result"

    bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "SCOPE_DRIFT" \
      "Changed files outside allowed scope" "N/A" \
      "Agent modified files outside scope: $item_scope" \
      "$(git diff --cached --name-only 2>/dev/null | tr '\n' ', ')"

    git reset HEAD 2>/dev/null || true
    bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "blocked"
    echo "  Item marked [blocked] — needs human review."
    echo "SCOPE_DRIFT" > "$status_file"
    popd > /dev/null
    return 0
  fi

  # Check if there are any changes at all
  local has_changes
  has_changes=$(git diff --cached --name-only | head -1 || true)
  if [[ -z "$has_changes" ]]; then
    local committed_changes
    committed_changes=$(git log "${BASE_BRANCH}..HEAD" --oneline 2>/dev/null | head -1 || true)
    if [[ -z "$committed_changes" ]]; then
      echo "  No changes produced. Agent may have gotten stuck."
      bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "FAILURE" \
        "No changes produced" "N/A" "Agent produced no changes — may need clearer instructions" ""
      bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" " "
      echo "FAILURE" > "$status_file"
      popd > /dev/null
      return 0
    fi
  fi

  # Commit staged changes (already added above)
  if [[ -n "$has_changes" ]]; then
    git commit -m "item-${item_number}: ${item_title}" 2>/dev/null || true
  fi

  popd > /dev/null

  # Success — mark item done
  bash "${LIB_DIR}/parse-plan.sh" "$PLAN_FILE" mark "$item_number" "x"

  # Log success
  local changed_files
  changed_files=$(cd "$worktree_path" && git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | tr '\n' ', ')
  bash "${LIB_DIR}/evolve.sh" "$REPO_DIR" log "$item_number" "$item_title" "SUCCESS" \
    "none" "N/A" "Completed successfully" "$changed_files"

  echo "  Item #${item_number} complete!"

  # Create PR and run reviews (non-blocking)
  if command -v gh &>/dev/null; then
    echo "  Creating PR and running reviews..."
    (
      cd "$worktree_path"
      bash "${LIB_DIR}/pr.sh" "$worktree_path" "$item_number" "$item_title" "$BASE_BRANCH"
    ) &
    BG_PIDS+=($!)
    echo "  PR creation running in background (PID: ${BG_PIDS[-1]})"
  fi

  echo "SUCCESS" > "$status_file"
  return 0
}

# ─── Main loop ───────────────────────────────────────────────────────────────
main() {
  preflight

  if [[ "$MODE" == "--status" ]]; then
    show_status
    exit 0
  fi

  echo ""
  echo "╔═══════════════════════════════════════════════════╗"
  echo "║  LOOPWORK — Ralph Loop                            ║"
  echo "║  Mode: $(printf '%-42s' "$MODE")║"
  echo "║  Repo: $(printf '%-42s' "$(basename "$REPO_DIR")")║"
  echo "╚═══════════════════════════════════════════════════╝"
  echo ""

  show_status

  local iteration=0
  local consecutive_failures=0
  local status_file="${WORKFLOW_DIR}/.iteration_status"

  while true; do
    iteration=$((iteration + 1))
    echo ""
    echo "═══ Iteration ${iteration} ═══"

    # Run iteration directly (not in subshell) so interactive mode works
    echo "" > "$status_file"
    run_iteration "$MODE" "$status_file"

    # Read status from file
    local status
    status=$(cat "$status_file" 2>/dev/null || echo "UNKNOWN")

    if [[ "$status" == "ALL_DONE" ]]; then
      echo ""
      echo "All items complete! Cleaning up..."
      bash "${LIB_DIR}/worktree.sh" "$REPO_DIR" cleanup "$BASE_BRANCH"
      show_status
      echo "Done."
      exit 0
    fi

    # Check for consecutive failures
    if [[ "$status" == "FAILURE" || "$status" == "SCOPE_DRIFT" || "$status" == "BLOCKED" ]]; then
      consecutive_failures=$((consecutive_failures + 1))
      if [[ $consecutive_failures -ge $MAX_RETRIES ]]; then
        echo ""
        echo "ERROR: ${MAX_RETRIES} consecutive failures. Stopping." >&2
        echo "Check EVOLUTION_LOG.md for details." >&2
        show_status
        exit 1
      fi
    else
      consecutive_failures=0
    fi

    # Brief pause between iterations
    if [[ "$MODE" == "--auto" ]]; then
      echo "  Pausing ${PAUSE_BETWEEN_ITEMS}s before next iteration..."
      sleep "$PAUSE_BETWEEN_ITEMS"
    else
      echo ""
      read -rp "Continue to next item? [Y/n/status/quit] " choice
      case "$choice" in
        n|N|quit|q) echo "Stopped."; exit 0 ;;
        status|s) show_status; continue ;;
        *) ;;  # Continue
      esac
    fi
  done
}

main
