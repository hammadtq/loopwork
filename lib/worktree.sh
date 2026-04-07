#!/usr/bin/env bash
# worktree.sh — Manage git worktrees for parallel item execution.

set -euo pipefail

REPO_DIR="${1:?Usage: worktree.sh <repo-dir> <command> [args...]}"
COMMAND="${2:?Command required: create|remove|list|cleanup}"
WORKTREE_BASE="${REPO_DIR}/.workflow/worktrees"

mkdir -p "$WORKTREE_BASE"

# ─── Create a worktree for an item ──────────────────────────────────────────
create_worktree() {
  local item_number="${1:?Item number required}"
  local base_branch="${2:-main}"

  local branch_name="item-${item_number}"
  local worktree_path="${WORKTREE_BASE}/${branch_name}"

  cd "$REPO_DIR"

  # Refresh base branch from origin so we are not branching from a stale local
  # ref. Failure (e.g. no remote, offline) is non-fatal.
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch origin "$base_branch" >/dev/null 2>&1 || true
  fi

  # If a worktree directory already exists, it is leftover from a previous
  # attempt of the same item. Silently reusing it caused stale state to leak
  # between iterations, so we clean it up and recreate from a fresh base.
  if [[ -d "$worktree_path" ]]; then
    echo "WARNING: Removing stale worktree from previous run: $worktree_path" >&2
    git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    rm -rf "$worktree_path"
    git worktree prune >/dev/null 2>&1 || true
    git branch -D "$branch_name" >/dev/null 2>&1 || true
  fi

  # Create branch from base if it doesn't exist. Prefer origin/<base> when
  # available so we always start from the freshest remote tip.
  local base_ref="$base_branch"
  if git show-ref --verify --quiet "refs/remotes/origin/${base_branch}"; then
    base_ref="origin/${base_branch}"
  fi

  if ! git show-ref --verify --quiet "refs/heads/${branch_name}"; then
    git branch "$branch_name" "$base_ref"
  fi

  # Create worktree
  git worktree add "$worktree_path" "$branch_name" 2>/dev/null || {
    echo "ERROR: Failed to create worktree at $worktree_path" >&2
    return 1
  }

  echo "$worktree_path"
}

# ─── Remove a worktree ──────────────────────────────────────────────────────
remove_worktree() {
  local item_number="${1:?Item number required}"
  local delete_branch="${2:-false}"

  local branch_name="item-${item_number}"
  local worktree_path="${WORKTREE_BASE}/${branch_name}"

  cd "$REPO_DIR"

  if [[ -d "$worktree_path" ]]; then
    git worktree remove "$worktree_path" --force 2>/dev/null || {
      echo "WARNING: Force-removing worktree $worktree_path" >&2
      rm -rf "$worktree_path"
      git worktree prune
    }
  fi

  if [[ "$delete_branch" == "true" ]]; then
    git branch -D "$branch_name" 2>/dev/null || true
  fi

  echo "Removed worktree for item ${item_number}"
}

# ─── List active worktrees ──────────────────────────────────────────────────
list_worktrees() {
  cd "$REPO_DIR"
  git worktree list --porcelain | awk '/^worktree / { path=$2 } /^branch / { branch=$2; print path "\t" branch }'
}

# ─── Cleanup merged worktrees ───────────────────────────────────────────────
cleanup_worktrees() {
  local base_branch="${1:-main}"

  cd "$REPO_DIR"

  # Find item branches that are merged into base
  local merged_branches
  merged_branches=$(git branch --merged "$base_branch" | grep 'item-' | xargs || true)

  if [[ -z "$merged_branches" ]]; then
    echo "No merged worktrees to clean up"
    return 0
  fi

  for branch in $merged_branches; do
    local item_number
    item_number=$(echo "$branch" | sed 's/item-//')
    echo "Cleaning up merged worktree: item-${item_number}" >&2
    remove_worktree "$item_number" "true"
  done
}

# ─── Check for scope overlap between active worktrees ────────────────────────
check_overlap() {
  local new_scope="${1:?Scope required}"
  local plan_file="${2:?Plan file required}"

  # Get active worktree item numbers
  local active_items
  active_items=$(list_worktrees | grep 'item-' | sed 's/.*item-//' | cut -f1)

  if [[ -z "$active_items" ]]; then
    echo "NO_OVERLAP"
    return 0
  fi

  # For each active worktree, check if scopes overlap
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  for item_num in $active_items; do
    # Get that item's scope from the plan
    local item_scope
    item_scope=$(cd "$REPO_DIR" && grep -A5 "^### \[wip\] ${item_num}\." "$plan_file" | grep '^\- \*\*Scope\*\*' | sed 's/^- \*\*Scope\*\*: //' | tr -d '`' || true)

    [[ -z "$item_scope" ]] && continue

    # Check if any directories overlap
    IFS=',' read -ra new_dirs <<< "$new_scope"
    IFS=',' read -ra active_dirs <<< "$item_scope"

    for new_dir in "${new_dirs[@]}"; do
      new_dir=$(echo "$new_dir" | xargs)
      new_dir="${new_dir%/}"
      [[ -z "$new_dir" ]] && continue
      for active_dir in "${active_dirs[@]}"; do
        active_dir=$(echo "$active_dir" | xargs)
        active_dir="${active_dir%/}"
        [[ -z "$active_dir" ]] && continue
        # Overlap if equal, or if either is a directory ancestor of the other
        # (use '/' boundary so "src/api" does not match "src/apiary").
        if [[ "$new_dir" == "$active_dir" || \
              "$new_dir" == "${active_dir}/"* || \
              "$active_dir" == "${new_dir}/"* ]]; then
          echo "OVERLAP:item-${item_num}:${active_dir}"
          return 1
        fi
      done
    done
  done

  echo "NO_OVERLAP"
  return 0
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
case "$COMMAND" in
  create)  create_worktree "${3:?}" "${4:-main}" ;;
  remove)  remove_worktree "${3:?}" "${4:-false}" ;;
  list)    list_worktrees ;;
  cleanup) cleanup_worktrees "${3:-main}" ;;
  overlap) check_overlap "${3:?}" "${4:?}" ;;
  *)       echo "Usage: worktree.sh <repo-dir> <create|remove|list|cleanup|overlap> [args]" >&2; exit 1 ;;
esac
