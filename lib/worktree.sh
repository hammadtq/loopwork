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

  # If worktree already exists, return its path
  if [[ -d "$worktree_path" ]]; then
    echo "$worktree_path"
    return 0
  fi

  cd "$REPO_DIR"

  # Create branch from base if it doesn't exist
  if ! git show-ref --verify --quiet "refs/heads/${branch_name}"; then
    git branch "$branch_name" "$base_branch"
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
      for active_dir in "${active_dirs[@]}"; do
        active_dir=$(echo "$active_dir" | xargs)
        # Check prefix overlap in either direction
        if [[ "$new_dir" == ${active_dir}* || "$active_dir" == ${new_dir}* ]]; then
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
