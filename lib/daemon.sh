#!/usr/bin/env bash
# daemon.sh — Lifecycle manager for backgrounded loopwork processes.
#
# Usage: daemon.sh <repo-dir> <start|stop|tail|status>
#
# State files (in <repo-dir>/.workflow/):
#   loop.pid  — PID of backgrounded run.sh
#   loop.log  — all stdout/stderr from run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOPWORK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_DIR="${1:?Usage: daemon.sh <repo-dir> <start|stop|tail|status>}"
if [[ ! -d "$REPO_DIR" ]]; then
  echo "ERROR: Directory not found: $REPO_DIR" >&2
  exit 1
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
COMMAND="${2:?Command required: start|stop|tail|status}"

WORKFLOW_DIR="${REPO_DIR}/.workflow"
PID_FILE="${WORKFLOW_DIR}/loop.pid"
LOG_FILE="${WORKFLOW_DIR}/loop.log"
PLAN_FILE="${REPO_DIR}/MASTER_PLAN.md"

# ─── Helpers ─────────────────────────────────────────────────────────────────
is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    else
      # Stale PID file — clean up
      rm -f "$PID_FILE"
      return 1
    fi
  fi
  return 1
}

# ─── Start ───────────────────────────────────────────────────────────────────
do_start() {
  # Check if already running
  local existing_pid
  if existing_pid=$(is_running); then
    echo "ERROR: Loop already running (PID $existing_pid)" >&2
    echo "  Use 'daemon.sh $REPO_DIR stop' to stop it first." >&2
    return 1
  fi

  # Check for MASTER_PLAN.md
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "ERROR: No MASTER_PLAN.md found in $REPO_DIR" >&2
    return 1
  fi

  # Check for git repo
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    echo "ERROR: $REPO_DIR is not a git repository" >&2
    return 1
  fi

  mkdir -p "$WORKFLOW_DIR"

  # Clear log for fresh start (keep old log as .prev)
  if [[ -f "$LOG_FILE" ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.prev"
  fi

  # Launch run.sh in background with nohup
  # The bash -c wrapper ensures PID file is cleaned up on exit
  nohup bash -c "bash '${LOOPWORK_DIR}/run.sh' '${REPO_DIR}' --auto 2>&1; rm -f '${PID_FILE}'" \
    >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  # Wait briefly and verify it started
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    echo "STARTED"
    echo "  PID:  $pid"
    echo "  Log:  $LOG_FILE"
    echo "  Plan: $PLAN_FILE"
    echo ""
    echo "  Monitor:  daemon.sh $REPO_DIR status"
    echo "  Watch:    daemon.sh $REPO_DIR tail"
    echo "  Stop:     daemon.sh $REPO_DIR stop"
  else
    echo "ERROR: Loop failed to start. Last 20 lines of log:" >&2
    tail -20 "$LOG_FILE" 2>/dev/null || true
    rm -f "$PID_FILE"
    return 1
  fi
}

# ─── Stop ────────────────────────────────────────────────────────────────────
do_stop() {
  local pid
  if ! pid=$(is_running); then
    echo "No loop running."
    return 0
  fi

  echo "Stopping loop (PID $pid)..."
  kill "$pid" 2>/dev/null || true

  # Wait up to 10 seconds for graceful shutdown
  local wait=0
  while [[ $wait -lt 10 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "STOPPED"
      rm -f "$PID_FILE"
      return 0
    fi
    sleep 1
    wait=$((wait + 1))
  done

  # Force kill if still alive
  echo "  Force killing..."
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "STOPPED (forced)"
}

# ─── Status ──────────────────────────────────────────────────────────────────
do_status() {
  local pid
  if pid=$(is_running); then
    echo "RUNNING (PID $pid)"
  else
    echo "NOT_RUNNING"
  fi

  # Show plan progress if plan exists
  if [[ -f "$PLAN_FILE" ]]; then
    echo ""
    echo "Plan progress:"
    bash "${LOOPWORK_DIR}/lib/parse-plan.sh" "$PLAN_FILE" count 2>/dev/null || true
  fi

  # Show recent log
  if [[ -f "$LOG_FILE" ]]; then
    echo ""
    echo "Recent log:"
    tail -10 "$LOG_FILE" 2>/dev/null || true
  fi
}

# ─── Tail ────────────────────────────────────────────────────────────────────
do_tail() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "No log file found at $LOG_FILE"
    return 1
  fi

  local pid
  if pid=$(is_running); then
    echo "Following log for running loop (PID $pid)..."
    echo "Press Ctrl+C to stop following."
    echo ""
    tail -f "$LOG_FILE"
  else
    echo "Loop is not running. Showing last 50 lines:"
    echo ""
    tail -50 "$LOG_FILE"
  fi
}

# ─── Dispatch ────────────────────────────────────────────────────────────────
case "$COMMAND" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  tail)   do_tail ;;
  *)
    echo "Usage: daemon.sh <repo-dir> <start|stop|tail|status>" >&2
    exit 1
    ;;
esac
