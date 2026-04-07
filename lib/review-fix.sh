#!/usr/bin/env bash
# review-fix.sh — Review-fix-resubmit loop for PRs.
#
# Flow:
#   1. Checkout PR branch
#   2. Run Claude + Codex reviews in parallel
#   3. Claude analyzes combined findings → classifies as CRITICAL / WARNING / INFO
#   4. If CRITICAL: Claude fixes the issues, commits, pushes
#   5. Re-review (loop back to step 2)
#   6. Repeat until clean or max iterations
#   7. Post final review summary to PR
#
# Usage: review-fix.sh <pr-ref> <workdir> [max-iterations]
#   pr-ref: owner/repo#N or just #N (uses current repo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Portable timeout (macOS lacks coreutils timeout) ────────────────────────
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
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

PR_REF="${1:?Usage: review-fix.sh <owner/repo#N> <workdir> [max-iterations]}"
WORK_DIR="${2:?Work directory required}"
MAX_ITERATIONS="${3:-5}"
REVIEW_DIR="${WORK_DIR}/.loopwork-reviews"
TIMEOUT="${WORKFLOW_TIMEOUT:-600}"

# Capture the caller's CWD before any pushd/cd, so that bare `#N` refs can be
# resolved against the user's current repo.
CALLER_CWD="$(pwd)"

# ─── Parse PR reference ──────────────────────────────────────────────────────
parse_pr_ref() {
  local ref="$1"
  local repo="" pr_number=""

  if [[ "$ref" == *"#"* ]]; then
    repo="${ref%%#*}"
    pr_number="${ref##*#}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    pr_number="$ref"
  else
    echo "ERROR: Cannot parse PR ref: $ref (expected owner/repo#N or #N)" >&2
    return 1
  fi

  # Resolve bare #N (no repo) by detecting the caller's current repo via gh.
  # This must run BEFORE any cd into WORK_DIR (an empty work directory).
  if [[ -z "$repo" ]]; then
    if command -v gh &>/dev/null; then
      repo=$(cd "$CALLER_CWD" 2>/dev/null && \
        gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    fi
    if [[ -z "$repo" ]]; then
      echo "ERROR: PR ref '$ref' has no owner/repo and current directory is not a GitHub repo." >&2
      echo "       Run with owner/repo#$pr_number, or invoke from inside the target repo." >&2
      return 1
    fi
  fi

  echo "$repo" "$pr_number"
}

# ─── Checkout PR ─────────────────────────────────────────────────────────────
checkout_pr() {
  local repo="$1"
  local pr_number="$2"

  pushd "$WORK_DIR" > /dev/null

  if [[ -n "$repo" ]]; then
    # Remote repo — clone if needed
    if [[ ! -d ".git" ]]; then
      gh repo clone "$repo" . >/dev/null 2>&1 || {
        echo "ERROR: Failed to clone $repo" >&2
        return 1
      }
    fi
    gh pr checkout "$pr_number" --repo "$repo" >/dev/null 2>&1 || {
      echo "ERROR: Failed to checkout PR #$pr_number from $repo" >&2
      return 1
    }
  else
    gh pr checkout "$pr_number" >/dev/null 2>&1 || {
      echo "ERROR: Failed to checkout PR #$pr_number" >&2
      return 1
    }
  fi

  local branch base_branch
  branch=$(git branch --show-current)
  base_branch=$(gh pr view "$pr_number" ${repo:+--repo "$repo"} --json baseRefName -q '.baseRefName' 2>/dev/null || echo "main")

  popd > /dev/null
  echo "$branch" "$base_branch"
}

# ─── Run parallel reviews ────────────────────────────────────────────────────
run_reviews() {
  local iteration="$1"
  local base_branch="$2"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  local claude_out="${REVIEW_DIR}/claude_iter${iteration}_${timestamp}.md"
  local codex_out="${REVIEW_DIR}/codex_iter${iteration}_${timestamp}.md"

  pushd "$WORK_DIR" > /dev/null

  # Get diff
  local diff
  diff=$(git diff "${base_branch}...HEAD" 2>/dev/null || git diff HEAD)

  if [[ -z "$diff" ]]; then
    echo "No changes to review."
    popd > /dev/null
    return 0
  fi

  local diff_file="${REVIEW_DIR}/diff_iter${iteration}.patch"
  echo "$diff" > "$diff_file"

  # Claude review
  if command -v claude &>/dev/null; then
    (
      run_with_timeout "$TIMEOUT" claude -p "You are a staff engineer doing a pre-merge code review.

Review this diff. For each finding, output in this EXACT format:
[CRITICAL] file:line — description
[WARNING] file:line — description
[INFO] file:line — description

Focus on: bugs, logic errors, security issues, missing edge cases, performance.
If the code is clean, output: [CLEAN] No critical or warning issues found.

Diff:
$(cat "$diff_file")" \
        --allowedTools "Read,Glob,Grep" \
        --max-turns 10 \
        --output-format text > "$claude_out" 2>/dev/null
    ) &
    local claude_pid=$!
  else
    echo "SKIP: claude CLI not found" > "$claude_out"
  fi

  # Codex review
  if command -v codex &>/dev/null; then
    (
      codex review --base "$base_branch" > "$codex_out" 2>/dev/null || \
        codex exec "Review the diff in ${diff_file}. For each finding use format: [CRITICAL], [WARNING], or [INFO] with file:line. If clean, say [CLEAN]." \
          -o "$codex_out" 2>/dev/null
    ) &
    local codex_pid=$!
  else
    echo "SKIP: codex CLI not found" > "$codex_out"
  fi

  # Wait
  [[ -n "${claude_pid:-}" ]] && wait "$claude_pid" 2>/dev/null || true
  [[ -n "${codex_pid:-}" ]] && wait "$codex_pid" 2>/dev/null || true

  popd > /dev/null

  # Output paths
  echo "$claude_out" "$codex_out"
}

# ─── Analyze findings — are there actionable issues? ─────────────────────────
has_actionable_issues() {
  local claude_file="$1"
  local codex_file="$2"

  # Match any non-trivial finding from either reviewer
  # Claude formats: [CRITICAL], [WARNING]
  # Codex formats: [P0], [P1], [P2], [HIGH], [MEDIUM], - High:, - Medium:
  # Only [INFO], [P3], [LOW], and [CLEAN] are skipped
  local pattern='\[CRITICAL\]|\[WARNING\]|\[P0\]|\[P1\]|\[P2\]|\[HIGH\]|\[MEDIUM\]|^- High:|^- Medium:'
  if grep -qiE "$pattern" "$claude_file" 2>/dev/null; then
    return 0
  fi
  if grep -qiE "$pattern" "$codex_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─── Fix issues found in review ──────────────────────────────────────────────
fix_issues() {
  local claude_file="$1"
  local codex_file="$2"
  local iteration="$3"

  local claude_review codex_review
  claude_review=$(cat "$claude_file" 2>/dev/null || echo "No Claude review")
  codex_review=$(cat "$codex_file" 2>/dev/null || echo "No Codex review")

  pushd "$WORK_DIR" > /dev/null

  local fix_prompt
  fix_prompt=$(cat <<PROMPT
You are fixing code review findings. Two reviewers (Claude and Codex) independently reviewed this code.

## Claude findings:
${claude_review}

## Codex findings:
${codex_review}

## Your task:
1. Fix ALL [CRITICAL], [P0], [P1], [HIGH] issues from both reviewers
2. Fix ALL [WARNING], [P2], [MEDIUM] issues from both reviewers
3. Do NOT fix [INFO], [P3], [LOW] issues — those are informational only
4. Do NOT add features, refactor, or make improvements beyond the specific fixes
5. Commit each fix with a clear message: "review-fix: <what was fixed>"

If both reviewers flagged the same issue, that is high confidence — fix it first.
If only one reviewer flagged it, use your judgment but err on the side of fixing.

Begin fixing now.
PROMPT
)

  echo "  Fixing issues (iteration $iteration)..."
  run_with_timeout "$TIMEOUT" claude -p "$fix_prompt" \
    --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
    --max-turns 30 \
    --output-format text > "${REVIEW_DIR}/fix_iter${iteration}.txt" 2>&1 || true

  # Stage and commit any uncommitted fixes
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -m "review-fix (iteration ${iteration}): address critical findings" 2>/dev/null || true
  fi

  popd > /dev/null
}

# ─── Post summary to PR ─────────────────────────────────────────────────────
post_pr_summary() {
  local repo="$1"
  local pr_number="$2"
  local final_claude="$3"
  local final_codex="$4"
  local iterations="$5"
  local clean="$6"

  local fix_count="${7:-0}"

  local status_emoji="🔍"
  local status_text="Review complete — manual review recommended"
  if [[ "$clean" == "true" && "$fix_count" -gt 0 ]]; then
    status_emoji="✅"
    status_text="All issues resolved (${fix_count} fix commit(s) pushed)"
  elif [[ "$clean" == "true" ]]; then
    status_emoji="✅"
    status_text="No issues found"
  fi

  local body
  body=$(cat <<EOF
## ${status_emoji} Automated Review (${iterations} iteration(s))

${status_text}

<details>
<summary>Claude Code Review</summary>

$(cat "$final_claude" 2>/dev/null || echo "Not available")
</details>

<details>
<summary>Codex Review</summary>

$(cat "$final_codex" 2>/dev/null || echo "Not available")
</details>

---
*Reviewed by [loopwork](https://github.com/hammadtq/loopwork)*
EOF
)

  if command -v gh &>/dev/null; then
    gh pr comment "$pr_number" ${repo:+--repo "$repo"} --body "$body" 2>/dev/null || {
      echo "WARNING: Failed to post PR comment" >&2
    }
  fi

  echo "$body"
}

# ─── Main loop ───────────────────────────────────────────────────────────────
main() {
  local repo pr_number parsed
  parsed=$(parse_pr_ref "$PR_REF") || return 1
  read -r repo pr_number <<< "$parsed"
  if [[ -z "$repo" || -z "$pr_number" ]]; then
    echo "ERROR: Could not resolve PR reference '$PR_REF'" >&2
    return 1
  fi

  echo ""
  echo "┌─────────────────────────────────────────────────┐"
  echo "│  REVIEW-FIX LOOP"
  echo "│  PR: ${repo:+$repo}#${pr_number}"
  echo "│  Max iterations: ${MAX_ITERATIONS}"
  echo "└─────────────────────────────────────────────────┘"

  # Checkout PR (clone into empty WORK_DIR first, then create review dirs)
  echo "  Checking out PR..."
  local checkout_result
  checkout_result=$(checkout_pr "$repo" "$pr_number") || {
    echo "  ERROR: Failed to checkout PR. Aborting review." >&2
    return 1
  }
  local branch base_branch
  read -r branch base_branch <<< "$checkout_result"
  echo "  Branch: $branch (base: $base_branch)"

  # Create review output directory after clone so it does not interfere
  mkdir -p "$REVIEW_DIR"

  local iteration=0
  local is_clean="false"
  local reviewer_failed="false"
  local last_claude="" last_codex=""

  while [[ $iteration -lt $MAX_ITERATIONS ]]; do
    iteration=$((iteration + 1))
    echo ""
    echo "  ═══ Review iteration ${iteration}/${MAX_ITERATIONS} ═══"

    # Run parallel reviews
    local review_files
    review_files=$(run_reviews "$iteration" "$base_branch")

    if [[ "$review_files" == "No changes to review." ]]; then
      echo "  No changes to review."
      is_clean="true"
      break
    fi

    read -r last_claude last_codex <<< "$review_files"

    echo "  Claude review: $last_claude"
    echo "  Codex review:  $last_codex"

    # Verify at least one review produced output — empty files mean the reviewer failed
    local claude_size codex_size
    claude_size=$(wc -c < "$last_claude" 2>/dev/null | tr -d ' ')
    codex_size=$(wc -c < "$last_codex" 2>/dev/null | tr -d ' ')
    if [[ "${claude_size:-0}" -eq 0 && "${codex_size:-0}" -eq 0 ]]; then
      echo "  ERROR: Both reviews produced empty output — reviewers may have failed."
      echo "  Treating as failure, not clean pass."
      reviewer_failed="true"
      break
    fi
    if [[ "${claude_size:-0}" -eq 0 ]]; then
      echo "  WARNING: Claude review is empty — reviewer may have failed."
    fi
    if [[ "${codex_size:-0}" -eq 0 ]]; then
      echo "  WARNING: Codex review is empty — reviewer may have failed."
    fi

    # Check for actionable issues (anything above INFO)
    if has_actionable_issues "$last_claude" "$last_codex"; then
      echo "  Issues found — fixing..."
      fix_issues "$last_claude" "$last_codex" "$iteration"

      # Push fixes
      pushd "$WORK_DIR" > /dev/null
      git push 2>/dev/null || {
        echo "  WARNING: Failed to push fixes" >&2
      }
      popd > /dev/null

      echo "  Fixes pushed — re-reviewing..."
    else
      echo "  No actionable issues — review clean!"
      is_clean="true"
      break
    fi
  done

  if [[ "$is_clean" != "true" ]]; then
    echo ""
    echo "  WARNING: Still has issues after ${MAX_ITERATIONS} iterations."
    echo "  Manual review needed."
  fi

  # Count how many fix commits were pushed
  pushd "$WORK_DIR" > /dev/null
  local fix_commits
  fix_commits=$(git log --oneline "${base_branch}..HEAD" --grep="review-fix" 2>/dev/null | wc -l | tr -d ' ')
  popd > /dev/null

  # Post summary to PR
  echo ""
  echo "  Posting review summary to PR..."
  local summary
  summary=$(post_pr_summary "$repo" "$pr_number" "$last_claude" "$last_codex" "$iteration" "$is_clean" "$fix_commits")

  # NOTE: Never auto-merge. Merging is always a human action.
  # The loop posts the review, marks the item done, and moves on.
  # Human merges via GitHub UI, Telegram, or CLI when ready.

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  REVIEW-FIX COMPLETE"
  echo "  PR:         https://github.com/${repo}/pull/${pr_number}"
  echo "  Iterations: ${iteration}"
  echo "  Clean:      ${is_clean}"
  echo "  Fixes:      ${fix_commits} commit(s) pushed"
  echo "  Status:     WAITING FOR YOUR MERGE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  → Review the PR and merge when ready."
  echo "  → The loop has already moved on to the next item."

  # Exit non-zero if reviewers failed or loop did not reach a clean state.
  # Caller (run.sh) uses this to mark the item [blocked] instead of [x],
  # which is critical for unattended (--auto) operation.
  if [[ "$reviewer_failed" == "true" ]]; then
    return 2
  fi
  if [[ "$is_clean" != "true" ]]; then
    return 1
  fi
  return 0
}

main
