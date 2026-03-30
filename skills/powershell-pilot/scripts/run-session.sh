#!/bin/bash
set -e

SESSION="${1:-default}"
SCRIPT_DIR="$(dirname "$0")"
LOG="/tmp/pwsh_sess_${SESSION}.log"

exec 3<>/tmp/pwsh_sess_${SESSION}_result || {
    echo "ERROR: could not open result FIFO — session FIFOs missing or corrupt. Run start-session.sh first." >&2
    exit 1
}

pwsh -NoProfile -NonInteractive -File "${SCRIPT_DIR}/runner.ps1" \
     -SessionName "$SESSION" \
     <>/tmp/pwsh_sess_${SESSION}_cmd 1>&3 \
     2>"$LOG" || {
    echo "ERROR: pwsh runner exited with code $?. Check $LOG for details." >&2
    exit 1
}
