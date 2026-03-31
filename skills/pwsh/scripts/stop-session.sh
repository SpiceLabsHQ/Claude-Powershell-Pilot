#!/bin/bash
# Usage: bash stop-session.sh <session>

SESSION="${1:-default}"

printf '%s\n' '__EXIT__' > "/tmp/pwsh_sess_${SESSION}_cmd" 2>/dev/null || true
sleep 1
rm -f "/tmp/pwsh_sess_${SESSION}_cmd" \
      "/tmp/pwsh_sess_${SESSION}_result" \
      "/tmp/pwsh_sess_${SESSION}.log" \
      "/tmp/pwsh_sess_${SESSION}.pid" \
      "/tmp/pwsh_session_${SESSION}.json" \
      /tmp/pwsh_${SESSION}_stdout_*.txt \
      /tmp/pwsh_${SESSION}_stderr_*.txt 2>/dev/null || true
echo "Session $SESSION closed"
