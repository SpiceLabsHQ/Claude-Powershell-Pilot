#!/bin/bash
# Usage: echo '<pwsh command>' | bash run-command.sh <session> [timeout] [grep_pattern]
# Sends a command to the named session and reads the output in one call.
# Avoids the need for $() command substitution when capturing the sentinel.

SESSION="${1:-default}"
TIMEOUT="${2:-120}"
PATTERN="${3:-}"

PID_FILE="/tmp/pwsh_sess_${SESSION}.pid"
if [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "ERROR: session runner is not running. Start it with run-session.sh." >&2
  exit 2
fi

CMD="$(cat)"
printf '%s\n' "$CMD" > "/tmp/pwsh_sess_${SESSION}_cmd"

IFS= read -r -t "$TIMEOUT" sentinel < "/tmp/pwsh_sess_${SESSION}_result"
if [ $? -ne 0 ]; then
  echo "ERROR: timed out waiting for response after ${TIMEOUT}s" >&2
  exit 1
fi

IFS=':' read -r _ exitCode stdoutFile stderrFile lineCount <<< "$sentinel"

echo "exit=$exitCode lines=$lineCount"

if [ -n "$PATTERN" ]; then
  grep -i "$PATTERN" "$stdoutFile" 2>/dev/null
elif [ "${lineCount:-0}" -le 100 ]; then
  cat "$stdoutFile" 2>/dev/null
else
  echo "[Output truncated — $lineCount lines. Re-run with a grep pattern to filter.]"
  head -20 "$stdoutFile" 2>/dev/null
fi

if [ "${exitCode}" != "0" ] && [ -s "$stderrFile" ]; then
  echo "--- stderr ---"
  cat "$stderrFile"
fi
