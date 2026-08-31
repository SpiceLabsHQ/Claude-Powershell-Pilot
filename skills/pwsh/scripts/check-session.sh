#!/bin/bash
# Usage: bash check-session.sh <session>
# Exits 0 if the runner is alive, 1 if dead or not started.

SESSION="${1:-default}"
PID_FILE="/tmp/pwsh_sess_${SESSION}.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "dead: no pid file — session never started or already stopped"
  exit 1
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
  echo "alive: pid=$PID"
  exit 0
else
  echo "dead: pid=$PID is no longer running"
  exit 1
fi
