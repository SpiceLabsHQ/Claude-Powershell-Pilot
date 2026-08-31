#!/bin/bash
# Usage: bash stop-session.sh <session>

SESSION="${1:-default}"
PID_FILE="/tmp/pwsh_sess_${SESSION}.pid"

# Kill the runner (bash) and its pwsh child process.
# Sending __EXIT__ via FIFO is unreliable when the runner has already died
# or when no reader is open; direct kill is the only safe approach.
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    pkill -TERM -P "$PID" 2>/dev/null || true  # terminate pwsh child
    kill -TERM "$PID" 2>/dev/null || true       # terminate the runner script
    sleep 0.5
    pkill -KILL -P "$PID" 2>/dev/null || true   # force-kill any surviving children
    kill -KILL "$PID" 2>/dev/null || true
  fi
fi

rm -f "/tmp/pwsh_sess_${SESSION}_cmd" \
      "/tmp/pwsh_sess_${SESSION}_result" \
      "/tmp/pwsh_sess_${SESSION}.log" \
      "/tmp/pwsh_sess_${SESSION}.pid" \
      "/tmp/pwsh_session_${SESSION}.json" \
      /tmp/pwsh_${SESSION}_stdout_*.txt \
      /tmp/pwsh_${SESSION}_stderr_*.txt 2>/dev/null || true
echo "Session $SESSION closed"
