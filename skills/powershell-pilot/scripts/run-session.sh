#!/bin/bash
set -e

SESSION="${1:-default}"
SCRIPT_DIR="$(dirname "$0")"

exec 3<>/tmp/pwsh_sess_${SESSION}_result && \
  pwsh -NoProfile -NonInteractive -File "${SCRIPT_DIR}/runner.ps1" \
       -SessionName "$SESSION" \
       <>/tmp/pwsh_sess_${SESSION}_cmd 1>&3 \
       2>/tmp/pwsh_sess_${SESSION}.log
