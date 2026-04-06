#!/usr/bin/env bash
# review.sh — Run cross-model code review (Claude Code + Codex) in parallel.
# Outputs combined review with areas of agreement/disagreement.

set -euo pipefail

REPO_DIR="${1:?Usage: review.sh <repo-dir> [base-branch]}"
BASE_BRANCH="${2:-main}"
REVIEW_DIR="${REPO_DIR}/.workflow/reviews"

mkdir -p "$REVIEW_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── Check tool availability ────────────────────────────────────────────────
has_claude() { command -v claude &>/dev/null; }
has_codex() { command -v codex &>/dev/null; }

# ─── Get the diff to review ─────────────────────────────────────────────────
get_diff() {
  cd "$REPO_DIR"
  git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || git diff HEAD
}

# ─── Claude Code review ─────────────────────────────────────────────────────
run_claude_review() {
  local diff_file="$1"
  local output="${REVIEW_DIR}/claude_${TIMESTAMP}.md"

  if ! has_claude; then
    echo "SKIP: claude CLI not found" > "$output"
    return
  fi

  cd "$REPO_DIR"
  claude -p "You are a staff engineer doing a pre-merge code review.

Review the following diff against the ${BASE_BRANCH} branch. Focus on:
1. Bugs, logic errors, edge cases
2. Security issues (OWASP top 10)
3. Performance concerns
4. Code style and consistency with the existing codebase
5. Missing error handling
6. Scope drift — does this diff do more than what was asked?

Be specific. Reference file:line. Rate severity: CRITICAL / WARNING / INFO.
If the code looks good, say so briefly.

Diff:
$(cat "$diff_file")" \
    --allowedTools "Read,Glob,Grep" \
    --max-turns 10 \
    --output-format text > "$output" 2>/dev/null || echo "ERROR: Claude review failed" > "$output"

  echo "$output"
}

# ─── Codex review ────────────────────────────────────────────────────────────
run_codex_review() {
  local output="${REVIEW_DIR}/codex_${TIMESTAMP}.md"

  if ! has_codex; then
    echo "SKIP: codex CLI not found" > "$output"
    return
  fi

  cd "$REPO_DIR"
  codex review --base "$BASE_BRANCH" > "$output" 2>/dev/null || \
    codex exec "Review the changes on this branch against ${BASE_BRANCH}. Focus on bugs, security, and scope drift." \
      -o "$output" 2>/dev/null || \
    echo "ERROR: Codex review failed" > "$output"

  echo "$output"
}

# ─── Merge reviews ──────────────────────────────────────────────────────────
merge_reviews() {
  local claude_file="$1"
  local codex_file="$2"
  local merged="${REVIEW_DIR}/merged_${TIMESTAMP}.md"

  cat > "$merged" <<EOF
# Code Review — ${TIMESTAMP}
**Branch:** $(cd "$REPO_DIR" && git branch --show-current)
**Base:** ${BASE_BRANCH}
**Files changed:** $(cd "$REPO_DIR" && git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | wc -l | xargs)

---

## Claude Code Review
$(cat "$claude_file")

---

## Codex Review
$(cat "$codex_file")

---

## Cross-Model Summary
<!-- The loop or a human reads this to decide: merge, fix, or reject -->
Both reviews completed. Check for overlapping findings (high confidence)
and unique findings (may need human judgment).
EOF

  echo "$merged"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  echo "Running cross-model review..." >&2

  # Save diff to temp file
  local diff_file="${REVIEW_DIR}/diff_${TIMESTAMP}.patch"
  get_diff > "$diff_file"

  if [[ ! -s "$diff_file" ]]; then
    echo "No changes to review." >&2
    return 0
  fi

  # Run reviews in parallel
  local claude_output codex_output
  claude_output="${REVIEW_DIR}/claude_${TIMESTAMP}.md"
  codex_output="${REVIEW_DIR}/codex_${TIMESTAMP}.md"

  run_claude_review "$diff_file" &
  local claude_pid=$!

  run_codex_review &
  local codex_pid=$!

  # Wait for both
  wait $claude_pid 2>/dev/null || true
  wait $codex_pid 2>/dev/null || true

  # Merge
  local merged
  merged=$(merge_reviews "$claude_output" "$codex_output")

  echo "Review complete: $merged" >&2
  echo "$merged"
}

main
