#!/usr/bin/env bash
# steer.sh — Check for STEER.md hotfile and apply it.
# Returns the steering content if found, archives the file.

set -euo pipefail

REPO_DIR="${1:?Usage: steer.sh <repo-dir>}"
STEER_FILE="${REPO_DIR}/STEER.md"
ARCHIVE_DIR="${REPO_DIR}/.workflow/steers"

mkdir -p "$ARCHIVE_DIR"

# ─── Check and apply ────────────────────────────────────────────────────────
if [[ -f "$STEER_FILE" ]]; then
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  CONTENT=$(cat "$STEER_FILE")

  # Archive it
  mv "$STEER_FILE" "${ARCHIVE_DIR}/STEER_APPLIED_${TIMESTAMP}.md"

  echo "STEER_FOUND"
  echo "---"
  echo "$CONTENT"
else
  echo "NO_STEER"
fi
