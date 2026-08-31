#!/bin/bash
# Usage: bash wait-ready.sh <session> [timeout_seconds]
#
# Blocks until runner.ps1 emits its READY startup signal on the result FIFO,
# then exits 0. Must be called ONCE, immediately after run-session.sh starts,
# before any run-command.sh calls.
#
# Why this exists:
#   pwsh cold-start on macOS with many installed modules can take 10-30+ seconds.
#   run-command.sh writes commands into the kernel FIFO buffer regardless of
#   whether pwsh has reached ReadLine() yet. If the caller's read times out
#   before the sentinel arrives, the sentinel ends up stranded in the result
#   FIFO buffer, desynchronising all subsequent command/sentinel pairs.
#   Waiting for READY guarantees the runner is in its main loop before any
#   command is issued.

SESSION="${1:-default}"
TIMEOUT="${2:-60}"
RESULT_PIPE="/tmp/pwsh_sess_${SESSION}_result"
LOG="/tmp/pwsh_sess_${SESSION}.log"

if [ ! -p "$RESULT_PIPE" ]; then
  echo "ERROR: result FIFO not found at $RESULT_PIPE — did start-session.sh run?" >&2
  exit 1
fi

line=""
if ! IFS= read -r -t "$TIMEOUT" line < "$RESULT_PIPE"; then
  echo "ERROR: runner did not become ready within ${TIMEOUT}s." >&2
  if [ -s "$LOG" ]; then
    echo "--- last log output ---" >&2
    tail -20 "$LOG" >&2
  else
    echo "Log is empty ($LOG) — pwsh may still be initializing or failed to start." >&2
    echo "Check that run-session.sh is still running (check-session.sh <session>)." >&2
  fi
  exit 1
fi

if [ "$line" = "READY" ]; then
  echo "Runner ready"
  exit 0
else
  echo "ERROR: expected READY, got: $line" >&2
  echo "The runner may be from an older version that does not emit a startup signal." >&2
  exit 1
fi
