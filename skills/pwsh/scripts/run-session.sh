#!/bin/bash
set -e

SESSION="${1:-default}"
SCRIPT_DIR="$(dirname "$0")"
LOG="/tmp/pwsh_sess_${SESSION}.log"
PID_FILE="/tmp/pwsh_sess_${SESSION}.pid"
STATE="/tmp/pwsh_session_${SESSION}.json"

echo $$ > "$PID_FILE"
# shellcheck disable=SC2064
trap "rm -f '$PID_FILE'" EXIT

# Record runner PID in session JSON so stop-session.sh can find it even
# without the .pid file (and for diagnostics).
if [ -f "$STATE" ]; then
  sed -i.bak "s/}$/,\"runnerPid\":$$}/" "$STATE" 2>/dev/null && rm -f "${STATE}.bak" || true
fi

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
