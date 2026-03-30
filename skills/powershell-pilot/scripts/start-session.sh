#!/bin/bash
set -e

SESSION="${1:-default}"
CMD_PIPE="/tmp/pwsh_sess_${SESSION}_cmd"
RESULT_PIPE="/tmp/pwsh_sess_${SESSION}_result"
STATE="/tmp/pwsh_session_${SESSION}.json"

# Return existing session if already running
if [ -f "$STATE" ]; then
  cat "$STATE"
  exit 0
fi

rm -f "$CMD_PIPE" "$RESULT_PIPE"
mkfifo "$CMD_PIPE" "$RESULT_PIPE"
printf '{"name":"%s","cmdPipe":"%s","resultPipe":"%s"}\n' \
  "$SESSION" "$CMD_PIPE" "$RESULT_PIPE" > "$STATE"
echo "Session $SESSION ready"
